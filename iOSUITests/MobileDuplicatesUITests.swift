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

    private func openDuplicates(fixture: String, dark: Bool = false, extra: [String] = []) {
        app.launchArguments =
            [
                "-EncryptedMemoriesUITestFixture", fixture, "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            ] + (dark ? ["-EncryptedMemoriesDarkAppearance"] : []) + extra
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
        XCTAssertTrue(app.staticTexts["Duplicates appear here when it is done."].exists)
        let progress = app.descendants(matching: .any).matching(identifier: "duplicates.checkProgress").firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "the check shows its progress")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '1,234 of 15,000 photos'"))
                .firstMatch.exists
                || (progress.value as? String)?.contains("1,234 of 15,000 photos") == true,
            "the progress counts the checked photos")
        XCTAssertFalse(app.staticTexts["No Duplicates"].exists)
    }

    /// Keeps a screenshot of the groups and of the running library check in light and dark for the visual review.
    func testScreenshotsOfTheGroupsAndTheLibraryCheck() {
        for dark in [false, true] {
            openDuplicates(fixture: "-EncryptedMemoriesDuplicatesFixture", dark: dark)
            XCTAssertTrue(group(1).waitForExistence(timeout: 10))
            XCTAssertTrue(
                app.staticTexts["4 identical copies"].waitForExistence(timeout: 5), "the screen counts every copy")
            keepScreenshot("duplicates-ios-groups-\(dark ? "dark" : "light")")
            member(0, 1).tap()
            XCTAssertTrue(app.buttons["duplicates.viewer.merge"].waitForExistence(timeout: 10))
            keepScreenshot("duplicates-ios-viewer-\(dark ? "dark" : "light")")
            // The same viewer as the library opens it, for comparison.
            app.buttons["Close"].firstMatch.tap()
            app.buttons["Library"].firstMatch.tap()
            let photo = libraryPhotoBelowTheBars()
            XCTAssertTrue(photo.waitForExistence(timeout: 20))
            photo.tap()
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
            keepScreenshot("library-ios-viewer-\(dark ? "dark" : "light")")
            app.terminate()

            openDuplicates(fixture: "-EncryptedMemoriesDuplicatesCheckingFixture", dark: dark)
            XCTAssertTrue(app.staticTexts["Checking Your Library"].waitForExistence(timeout: 10))
            keepScreenshot("duplicates-ios-checking-\(dark ? "dark" : "light")")
            app.terminate()
        }
    }

    /// A grid photo whose frame lies completely below the top bars. The first grid photo can sit partly under them,
    /// and a tap there scrolls the grid instead of opening the photo.
    private func libraryPhotoBelowTheBars() -> XCUIElement {
        let photos = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch.frame
        for index in 0..<min(photos.count, 40) {
            let photo = photos.element(boundBy: index)
            if photo.frame.minY > window.minY + 160, photo.frame.maxY < window.maxY - 160 { return photo }
        }
        return photos.firstMatch
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

    private func member(_ group: Int, _ index: Int) -> XCUIElement {
        app.buttons["duplicates.member.\(group).\(index)"]
    }

    private func waitUntil(_ element: XCUIElement, _ predicate: String, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, message)
    }

    func testTappingAPhotoOpensItWithItsGroupAndKeepsItThere() {
        openDuplicates()
        let ranked = member(0, 0)
        let other = member(0, 1)
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        XCTAssertTrue(ranked.isSelected, "the ranked photo is kept first")
        XCTAssertFalse(other.isSelected)
        XCTAssertTrue(other.label.hasPrefix("Copy 2 of 2"), "each copy says its position, got \(other.label)")

        other.tap()

        let keep = app.buttons["duplicates.viewer.keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10), "a tap opens the photo with the merge tools")
        XCTAssertEqual(keep.label, "Keep This Copy")
        for action in ["Favorite", "Info"] {
            XCTAssertTrue(app.buttons[action].firstMatch.exists, "the viewer keeps the library action \(action)")
        }
        keep.tap()
        waitUntil(keep, "label == 'Kept'", "the shown photo is kept")

        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        waitUntil(other, "isSelected == true", "the list keeps the photo chosen in the viewer")
        XCTAssertFalse(ranked.isSelected)
        XCTAssertTrue(other.label.contains(", kept"), "the kept copy says so, got \(other.label)")
    }

    func testMergeInTheViewerMergesTheGroupAndClosesTheViewer() {
        openDuplicates()
        let other = member(0, 1)
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        let merge = app.buttons["duplicates.viewer.merge"]
        XCTAssertTrue(merge.waitForExistence(timeout: 10))

        merge.tap()

        waitUntilGone(merge, "the viewer closes")
        waitUntilGone(group(1), "the merged group leaves the list")
        XCTAssertTrue(group(0).exists, "the other group stays")
    }

    func testSwipingDownClosesTheViewerOfAGroupLikeTheLibraryViewer() {
        openDuplicates()
        let other = member(0, 1)
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer opened")

        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 400)))

        waitUntilGone(close, "swiping down closes the viewer")
        XCTAssertTrue(group(0).waitForExistence(timeout: 10), "the duplicates return")
    }

    /// Closing the viewer returns to the list as it was; only opening the screen and pulling to refresh scan again.
    func testClosingTheViewerDoesNotScanTheLibraryAgain() {
        openDuplicates(
            fixture: "-EncryptedMemoriesDuplicatesFixture", extra: ["-EncryptedMemoriesDuplicatesRescanDropsGroup"])
        XCTAssertTrue(group(1).waitForExistence(timeout: 10))
        let other = member(0, 1)
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer opened")

        close.tap()

        XCTAssertTrue(group(0).waitForExistence(timeout: 10))
        // A scan after the viewer would drop the last group of this fixture.
        let dropped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: group(1))
        XCTAssertEqual(XCTWaiter.wait(for: [dropped], timeout: 4), .timedOut, "the list did not scan again")
    }

    func testPullToRefreshScansTheLibraryAgain() {
        openDuplicates(
            fixture: "-EncryptedMemoriesDuplicatesFixture", extra: ["-EncryptedMemoriesDuplicatesRescanDropsGroup"])
        XCTAssertTrue(group(1).waitForExistence(timeout: 10))

        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 400)))

        waitUntilGone(group(1), "a refresh scans again and the fixture drops the last group")
    }

    func testTheContextMenuKeepsAnotherPhoto() {
        openDuplicates()
        let other = member(0, 1)
        XCTAssertTrue(other.waitForExistence(timeout: 5))

        other.press(forDuration: 1.2)
        let byIdentifier = app.buttons["duplicates.keepMenu"].firstMatch
        let keep = byIdentifier.waitForExistence(timeout: 5) ? byIdentifier : app.buttons["Keep This Copy"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "the context menu offers Keep This Copy")
        keep.tap()

        waitUntil(other, "isSelected == true", "the photo from the context menu is kept")
        XCTAssertFalse(member(0, 0).isSelected)
    }
}
