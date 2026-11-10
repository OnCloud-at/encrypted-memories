import XCTest

/// Add Photos from an album's menu on the offline fixture account. The fixture album starts empty and its route
/// lists only the photos added to it.
final class MobileAlbumAddPhotosUITests: XCTestCase {
    private var app: XCUIApplication!
    /// The start of a photo tile's accessibility label in the launch language.
    private var photoLabelPrefix = "Photo, "

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
    }

    override func tearDown() { app.terminate() }

    func testAddPhotosAddsTheChosenPhotosAndShowsThemInTheAlbum() throws {
        launch()
        openFixtureAlbum()
        XCTAssertFalse(firstPhoto.exists, "the fixture album starts empty")

        openAddPhotos(menuItem: "Add Photos…")
        let bar = app.navigationBars["Add Photos"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the picker shows its title")
        let add = app.barButton(titled: "Add")
        XCTAssertFalse(add.isEnabled, "nothing is chosen yet")
        attachScreenshot("Add Photos picker at rest")
        // The grid opens at the newest photos, so its top row can be cut by the grid's own edge; the bar never
        // covers a row.
        let grid = app.descendants(matching: .any)["albums.addPhotos.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "the picker grid is reachable")
        XCTAssertGreaterThanOrEqual(grid.frame.minY, bar.frame.maxY - 0.5, "the grid starts below the bar")
        let firstShown = try XCTUnwrap(fullyShownPhotos().first, "no photo row shows completely below the bar")
        XCTAssertTrue(firstShown.isHittable, "the first fully shown photo can be tapped")
        choosePhotos(2)
        XCTAssertTrue(bar.exists, "the title stays while photos are chosen")
        XCTAssertTrue(app.staticTexts["2 Items Selected"].waitForExistence(timeout: 10), "the count shows below it")
        XCTAssertTrue(add.isEnabled)
        attachScreenshot("Add Photos picker with two photos chosen")
        add.tap()

        XCTAssertTrue(add.waitUntilGone(timeout: 20) == .completed, "the picker closes after the add")
        assertAlbumShowsTwoPhotos()
        attachScreenshot("Album after Add Photos")
    }

    func testCancelLeavesTheAlbumUnchanged() {
        launch()
        openFixtureAlbum()
        openAddPhotos(menuItem: "Add Photos…")
        choosePhotos(1)
        let cancel = app.barButton(titled: "Cancel")
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()

        XCTAssertTrue(app.barButton(titled: "Add").waitUntilGone(timeout: 10) == .completed)
        XCTAssertFalse(firstPhoto.waitForExistence(timeout: 3), "a cancelled picker adds nothing")
    }

    func testAPartialFailureKeepsThePickerAndTheSelectionForARetry() {
        launch(extraArguments: ["-EncryptedMemoriesAlbumAddPartialFailure"])
        openFixtureAlbum()
        openAddPhotos(menuItem: "Add Photos…")
        choosePhotos(2)
        let add = app.barButton(titled: "Add")
        add.tap()

        let failure = app.alerts["Couldn’t add to album"]
        XCTAssertTrue(failure.waitForExistence(timeout: 20), "a partial add shows the add failure")
        failure.buttons.firstMatch.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the picker stays open")
        XCTAssertTrue(app.staticTexts["2 Items Selected"].exists, "the selection stays for a retry")

        add.tap()
        XCTAssertTrue(add.waitUntilGone(timeout: 20) == .completed, "the retry adds and closes the picker")
        assertAlbumShowsTwoPhotos()
    }

    func testTheGermanPickerUsesTheApprovedTexts() {
        launch(language: "de", locale: "de_DE")
        openFixtureAlbum(collections: "Sammlungen")
        openAddPhotos(menuItem: "Fotos hinzufügen …", moreActions: "Weitere Albumaktionen")
        XCTAssertTrue(app.navigationBars["Fotos hinzufügen"].waitForExistence(timeout: 10))
        let add = app.barButton(titled: "Hinzufügen")
        XCTAssertTrue(add.exists)
        choosePhotos(1)
        XCTAssertTrue(app.navigationBars["Fotos hinzufügen"].exists, "the German title stays complete")
        XCTAssertTrue(app.staticTexts["1 Objekt ausgewählt"].waitForExistence(timeout: 10))
        attachScreenshot("German Add Photos picker with its title and one photo counted")
        app.barButton(titled: "Abbrechen").tap()
        XCTAssertTrue(add.waitUntilGone(timeout: 10) == .completed)
    }

    // MARK: Steps

    private func launch(language: String = "en", locale: String = "en_US", extraArguments: [String] = []) {
        if language == "de" { photoLabelPrefix = "Foto, " }
        app.launchArguments +=
            [
                "-EncryptedMemoriesUITestFixture", "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
            ] + extraArguments
        app.launch()
    }

    private func openFixtureAlbum(collections: String = "Collections") {
        let tab = app.buttons[collections].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 60))
        tab.tap()
        // The albums follow the library rows; the list loads them once they scroll in.
        let album = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Fixture Album'")).firstMatch
        for _ in 0..<4 where !album.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(album.waitForExistence(timeout: 10), "Collections lists the fixture album")
        album.tap()
    }

    private func openAddPhotos(menuItem: String, moreActions: String = "More album actions") {
        let more = app.buttons[moreActions].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        let item = app.buttons[menuItem].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the album menu offers \(menuItem)")
        item.tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 30), "the picker shows the library")
    }

    /// Taps the first `count` photos that show completely in the picker grid.
    private func choosePhotos(_ count: Int) {
        let shown = fullyShownPhotos()
        XCTAssertGreaterThanOrEqual(shown.count, count, "the picker shows too few complete photos")
        for photo in shown.prefix(count) { photo.tap() }
    }

    /// Photo tiles that lie completely below the navigation bar and inside the window, in grid order.
    private func fullyShownPhotos() -> [XCUIElement] {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        let bar = app.navigationBars.firstMatch.frame
        // A vertical bar (iPhone Duo outer display) stands beside the grid, so only a horizontal bar covers rows.
        let barBottom = bar.width > window.width / 2 ? bar.maxY : window.minY
        return photos.allElementsBoundByIndex.filter { photo in
            let frame = photo.frame
            return frame.minY >= barBottom - 0.5 && frame.maxY <= window.maxY + 0.5 && !frame.isEmpty
        }
    }

    private var photos: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", photoLabelPrefix))
    }

    private var firstPhoto: XCUIElement { photos.firstMatch }

    private func assertAlbumShowsTwoPhotos() {
        XCTAssertTrue(photos.element(boundBy: 1).waitForExistence(timeout: 20), "the album shows the added photos")
        XCTAssertFalse(photos.element(boundBy: 2).exists, "the album shows only the added photos")
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
