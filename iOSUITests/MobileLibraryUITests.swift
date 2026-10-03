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

    /// Swiping down closes the viewer for a video too, also while its stream cannot play.
    func testSwipingDownOnAVideoClosesTheViewer() {
        XCTAssertTrue(firstVideo.waitForExistence(timeout: 60), "the library grid shows no video")
        firstVideo.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "the viewer did not open")

        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 400)))

        XCTAssertTrue(wait(for: app.buttons["Close"], "exists == false"), "swiping down did not close the viewer")
        XCTAssertTrue(firstVideo.waitForExistence(timeout: 10), "the library did not return")
    }

    func testTheAlbumButtonOfTheViewerAddsTheOpenPhotoToAnAlbum() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        firstPhoto.tap()

        let addToAlbum = app.buttons["Add to Album"].firstMatch
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10), "the viewer shows no album button")
        addToAlbum.tap()
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10), "the album list did not open")
        XCTAssertTrue(album.isEnabled, "the photo is in the album before it was added")
        album.tap()
        XCTAssertTrue(wait(for: album, "exists == false"), "adding the photo did not close the album list")

        // The album list opens again and marks the album that already holds the photo.
        addToAlbum.tap()
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: album, "isEnabled == false"), "the album does not hold the photo")
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

    func testReturningFromBackgroundRestoresTheViewerWithPreviewProtection() {
        app.terminate()
        app.launchArguments += ["-EncryptedMemories.blurAppPreview", "YES"]
        app.launch()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        firstPhoto.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        app.activate()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
    }

    func testPrivacyPreviewSwitchPersistsAfterClosingSettings() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()

        let previewSwitch = app.switches["Blur App Preview"]
        XCTAssertTrue(previewSwitch.waitForExistence(timeout: 5))
        let initialValue = try XCTUnwrap(previewSwitch.value as? String)
        XCTAssertTrue(initialValue == "0" || initialValue == "1")
        let changedValue = initialValue == "0" ? "1" : "0"
        previewSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: previewSwitch, "value == '\(changedValue)'"))

        app.buttons["Settings"].tap()
        app.buttons["Done"].tap()
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let reopenedSwitch = app.switches["Blur App Preview"]
        XCTAssertEqual(reopenedSwitch.value as? String, changedValue)
        reopenedSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: reopenedSwitch, "value == '\(initialValue)'"))
    }

    func testPrivacySwitchHidesTheMapTab() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        XCTAssertTrue(app.tabBars.buttons["Map"].exists)

        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let mapSwitch = app.switches["Map and Places"]
        XCTAssertTrue(mapSwitch.waitForExistence(timeout: 5))
        XCTAssertEqual(mapSwitch.value as? String, "1")
        mapSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: mapSwitch, "value == '0'"))
        app.buttons["Settings"].tap()
        app.buttons["Done"].tap()

        XCTAssertTrue(wait(for: app.tabBars.buttons["Map"], "exists == false"))
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
    }

    func testRemoveLocationSwitchPersistsAfterClosingSettings() throws {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()

        let removeLocationSwitch = app.switches["Remove location when sharing"]
        XCTAssertTrue(removeLocationSwitch.waitForExistence(timeout: 5))
        let originalValue = try XCTUnwrap(removeLocationSwitch.value as? String)
        removeLocationSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changedValue = originalValue == "0" ? "1" : "0"
        XCTAssertTrue(wait(for: removeLocationSwitch, "value == '\(changedValue)'"))

        app.buttons["Settings"].tap()
        app.buttons["Done"].tap()
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let reopenedSwitch = app.switches["Remove location when sharing"]
        XCTAssertEqual(reopenedSwitch.value as? String, changedValue)
        reopenedSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: reopenedSwitch, "value == '\(originalValue)'"))
    }

    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Grid photos are accessibility elements named "Photo, <date>".
    private var firstPhoto: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo, '")).firstMatch
    }

    /// Grid videos are named "Video, <date>".
    private var firstVideo: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Video, '")).firstMatch
    }
}
