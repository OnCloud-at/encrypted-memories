import XCTest

final class MobileDuplicatesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() { app.terminate() }

    /// Opens Duplicates with the two fixture groups.
    private func openDuplicates() {
        openDuplicates(fixture: "-EncryptedMemoriesDuplicatesFixture")
        XCTAssertTrue(group(1).waitForExistence(timeout: 10))
    }

    private func openDuplicates(fixture: String) {
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", fixture, "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        // The iOS 26 and 27 tab bars do not always expose a tab bar element; the tab is a button in both.
        let collections = app.buttons["Collections"].firstMatch
        XCTAssertTrue(collections.waitForExistence(timeout: 60))
        collections.tap()

        // The list creates rows lazily; Utilities follows the Library rows below the fold on a phone.
        let entry = app.buttons["duplicates.entry"]
        for _ in 0..<4 where !entry.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
    }

    private func group(_ index: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "duplicates.group.\(index)").firstMatch
    }

    private func waitUntilGone(_ element: XCUIElement, _ message: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, message)
    }

    /// The system dialog lists its buttons twice in the accessibility tree; only one copy is hittable.
    private func dialogButton(_ identifier: String) -> XCUIElement {
        let matches = app.buttons.matching(identifier: identifier)
        for index in 0..<matches.count where matches.element(boundBy: index).isHittable {
            return matches.element(boundBy: index)
        }
        return matches.firstMatch
    }

    func testTheLibraryCheckShowsItsTitleAndProgressWhileNoDuplicateIsFound() {
        openDuplicates(fixture: "-EncryptedMemoriesDuplicatesCheckingFixture")

        XCTAssertTrue(app.staticTexts["Checking Your Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Duplicates appear here when the check is done."].exists)
        let progress = app.descendants(matching: .any).matching(identifier: "duplicates.checkProgress").firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "the check shows its progress")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '1,234 of 15,000 photos'"))
                .firstMatch.exists
                || (progress.value as? String)?.contains("1,234 of 15,000 photos") == true,
            "the progress counts the checked photos")
        XCTAssertFalse(app.staticTexts["No Duplicates"].exists)
    }

    func testMergeRemovesTheGroupFromDuplicates() {
        openDuplicates()
        let merge = app.buttons["duplicates.merge.0"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        merge.tap()

        waitUntilGone(group(1), "the merged group leaves the list")
        XCTAssertTrue(group(0).exists, "the other group stays")
    }

    func testMergeAllMergesEveryGroupAfterTheConfirmation() {
        openDuplicates()
        let mergeAll = app.buttons["duplicates.mergeAll"]
        XCTAssertTrue(mergeAll.waitForExistence(timeout: 5))
        mergeAll.tap()

        let confirm = dialogButton("duplicates.mergeAll.dialog")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        waitUntilGone(group(0), "every group leaves the list")
        XCTAssertTrue(app.staticTexts["No Duplicates"].waitForExistence(timeout: 5))
    }

    func testTappingAnotherPhotoKeepsItInsteadOfTheRankedOne() {
        openDuplicates()
        let ranked = app.buttons["duplicates.member.0.0"]
        let other = app.buttons["duplicates.member.0.1"]
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        XCTAssertTrue(ranked.isSelected, "the ranked photo is kept first")
        XCTAssertFalse(other.isSelected)

        other.tap()

        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: other)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed, "the tapped photo is kept")
        XCTAssertFalse(ranked.isSelected)
        XCTAssertEqual(other.label, "Photo to keep")
    }
}
