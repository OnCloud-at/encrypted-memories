import XCTest

final class MobilePagedBackupUITests: XCTestCase {
    func testLastPageIsReachableAndRow250KeepsItsDecisionAction() throws {
        let started = Date()
        continueAfterFailure = false
        let app = UITestApplication.make()
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesDeletedBackupFixture",
            "-EncryptedMemoriesDeletedBackupLargeFixture", "-EncryptedMemoriesProblemListSmoke",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let backup = app.buttons["backup.settings"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()
        let attention = app.buttons["backup.failedItems"]
        XCTAssertTrue(attention.waitForExistence(timeout: 30))
        attention.tap()
        let list = app.descendants(matching: .any).matching(identifier: "backup.problemList.fixture").firstMatch
        assertLoaded("loaded=5000;total=5000", list: list)

        let decision = row(250, in: app)
        assertHittable(decision)
        decision.tap()
        XCTAssertTrue(app.buttons["backup.keepDeleted.dialog"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backup.backUpAgain.dialog"].firstMatch.exists)
        try app.tapDialogButton("backup.keepDeleted.dialog")
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: decision)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 20), .completed)
        assertLoaded("loaded=4999;total=4999", list: list)

        let last = row(5_000, in: app)
        // Native lists can clamp the direct jump before the final row in a medium sheet.
        if !last.isHittable { list.swipeUp() }
        assertHittable(last)
        last.tap()
        XCTAssertTrue(app.buttons["backup.keepDeleted.dialog"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backup.backUpAgain.dialog"].firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Last page decision"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertLessThan(Date().timeIntervalSince(started), 120, "The native wiring smoke test must stay short")
    }

    private func row(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons["backup.failedItem.Deleted \(String(format: "%04d", number)) fixture.heic"].firstMatch
    }

    private func assertLoaded(_ value: String, list: XCUIElement) {
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: list)
        XCTAssertEqual(
            XCTWaiter.wait(for: [loaded], timeout: 30), .completed,
            "Expected \(value); observed \(String(describing: list.value))")
    }

    private func assertHittable(_ row: XCUIElement) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in row.isHittable }, object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 20), .completed)
    }
}
