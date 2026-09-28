import XCTest

/// Taps through the iOS app like a person does, on the offline fixture account: no Proton account, no network.
/// The app runs in English so the tests can find controls by their visible names.
final class MobileLibraryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-EncryptedMemoriesUITestFixture",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    func testLibraryShowsThePhotosOfTheAccount() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60), "the library grid shows no photo")
        XCTAssertTrue(app.buttons["Select"].exists)
    }

    /// iPhone Duo stacks the tabs and the toolbar items in a vertical bar on the side of the display. The grid then
    /// stays beside the bar, so no photo lies under a control, also in selection mode.
    func testThePhotoGridStaysBesideAVerticalBar() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        // One vertical bar holds the tabs and the toolbar items in a single column. An iPad sidebar also stacks
        // the tabs, but Select stays in the navigation bar there.
        let library = app.buttons["Library"].firstMatch.frame
        let collections = app.buttons["Collections"].firstMatch.frame
        let select = app.buttons["Select"].firstMatch.frame
        try XCTSkipUnless(
            abs(library.midX - collections.midX) < 1 && abs(library.midX - select.midX) < 1,
            "no vertical bar holds the tabs and the toolbar")

        assertPhotosStayBeside(bar: app.buttons["Library"].firstMatch)
        app.buttons["Select"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        assertPhotosStayBeside(bar: app.buttons["Share selected items"])
    }

    private func assertPhotosStayBeside(bar control: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let barFrame = control.frame
        let window = app.windows.firstMatch.frame
        let barOnTrailingEdge = barFrame.midX > window.midX
        let photos = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
        var checked = 0
        for index in 0..<min(photos.count, 40) {
            let photo = photos.element(boundBy: index).frame
            guard photo.intersects(window) else { continue }
            checked += 1
            let clear = barOnTrailingEdge ? photo.maxX <= barFrame.minX : photo.minX >= barFrame.maxX
            XCTAssertTrue(clear, "photo \(photo) lies under the vertical bar \(barFrame)", file: file, line: line)
        }
        XCTAssertGreaterThan(checked, 0, "no visible photo to check", file: file, line: line)
    }

    func testAPhotoOpensInTheViewerAndClosesAgain() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        firstPhoto.tap()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer did not open")
        XCTAssertTrue(app.buttons["Share"].exists, "the viewer bar shows no Share action")
        close.tap()

        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "the library did not return")
    }

    func testSelectingPhotosShowsTheirActionsAndDoneEndsTheSelection() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.buttons["Select"].tap()
        firstPhoto.tap()

        XCTAssertTrue(wait(for: firstPhoto, "isSelected == true"), "the tapped photo is not selected")
        XCTAssertTrue(app.buttons["Share selected items"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Move selected items to Trash"].isEnabled)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 5))
        XCTAssertTrue(wait(for: firstPhoto, "isSelected == false"), "Done must clear the selection")
    }

    func testTabsSwitchToCollectionsBackToTheLibraryAndToSearch() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))

        app.tabBars.buttons["Collections"].tap()
        XCTAssertTrue(wait(for: firstPhoto, "exists == false"), "the library grid stays visible under Collections")

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "the library did not return")

        // The search tab turns the tab bar into a search field, so it comes last.
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "Search shows no search field")
    }

    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Grid photos are accessibility elements named "Photo, <date>".
    private var firstPhoto: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo, '")).firstMatch
    }
}
