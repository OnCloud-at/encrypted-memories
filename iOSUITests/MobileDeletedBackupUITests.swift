import XCTest

final class MobileDeletedBackupUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesDeletedBackupFixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    /// The system dialog can list a button twice in the accessibility tree; the visible copy is the hittable one.
    private func dialogButton(_ identifier: String) -> XCUIElement {
        let matches = app.buttons.matching(identifier: identifier)
        for index in 0..<matches.count where matches.element(boundBy: index).isHittable {
            return matches.element(boundBy: index)
        }
        return matches.firstMatch
    }

    private func openDecision() {
        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let backup = app.buttons["backup.settings"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()
        let attention = app.buttons["backup.failedItems"]
        XCTAssertTrue(attention.waitForExistence(timeout: 10))
        XCTAssertTrue(attention.label.contains("1"), "One parked photo must need attention")
        attention.tap()
        let row = app.descendants(matching: .any).matching(identifier: "backup.failedItem.Deleted fixture.heic")
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["backup.keepDeleted.dialog"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backup.backUpAgain.dialog"].firstMatch.exists)
    }

    func testKeepDeletedRemovesDecisionRowAndAttentionCount() {
        openDecision()
        dialogButton("backup.keepDeleted.dialog").tap()
        XCTAssertTrue(app.staticTexts["Nothing needs attention."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let attention = app.buttons["backup.failedItems"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: attention)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        let deletionCount = app.buttons["backup.remoteDeletions"]
        XCTAssertTrue(deletionCount.waitForExistence(timeout: 5))
        XCTAssertTrue((deletionCount.value as? String)?.contains("1") == true)
    }

    func testBackUpAgainRemovesPermanentDecisionRow() {
        openDecision()
        dialogButton("backup.backUpAgain.dialog").tap()
        let row = app.descendants(matching: .any).matching(identifier: "backup.failedItem.Deleted fixture.heic")
            .firstMatch
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["backup.keepDeleted.dialog"].firstMatch.exists)
        XCTAssertFalse(app.buttons["backup.backUpAgain.dialog"].firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["backup.remoteDeletions"].exists)
    }
}
