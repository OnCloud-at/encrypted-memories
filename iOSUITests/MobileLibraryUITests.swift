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

    func testAPhotoOpensInTheViewerAndClosesAgain() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        visiblePhoto().tap()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer did not open")
        close.tap()

        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "the library did not return")
    }

    func testSelectingPhotosShowsTheirActionsAndDoneEndsTheSelection() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        app.buttons["Select"].tap()
        let photo = visiblePhoto()
        photo.tap()

        XCTAssertTrue(wait(for: photo, "isSelected == true"), "the tapped photo is not selected")
        XCTAssertTrue(app.buttons["Share selected items"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Move selected items to Trash"].isEnabled)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 5))
        XCTAssertTrue(wait(for: photo, "isSelected == false"), "Done must clear the selection")
    }

    func testTabsSwitchToCollectionsBackToTheLibraryAndToSearch() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))

        tab("Collections").tap()
        XCTAssertTrue(wait(for: firstPhoto, "exists == false"), "the library grid stays visible under Collections")

        tab("Library").tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "the library did not return")

        // The search tab turns the tab bar into a search field, so it comes last.
        tab("Search").tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "Search shows no search field")
    }

    func testPrivacySwitchHidesTheMapTab() {
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60))
        XCTAssertTrue(tab("Map").exists)

        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let mapSwitch = app.switches["Map and Places"]
        XCTAssertTrue(mapSwitch.waitForExistence(timeout: 5))
        XCTAssertEqual(mapSwitch.value as? String, "1")
        mapSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(wait(for: mapSwitch, "value == '0'"))
        backButton(to: "Settings").tap()
        app.buttons["Done"].tap()

        XCTAssertTrue(wait(for: tab("Map"), "exists == false"))
        XCTAssertTrue(tab("Library").exists)
    }

    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// A tab sits in the tab bar, or in the vertical bar on the side of the display on iPhone Duo, which is not a
    /// tab bar element.
    private func tab(_ name: String) -> XCUIElement {
        let tabBarButton = app.tabBars.buttons[name]
        return tabBarButton.exists ? tabBarButton : app.buttons[name].firstMatch
    }

    /// The back button shows the previous title in a horizontal bar. In the vertical bar on iPhone Duo it is a
    /// chevron without a title, which UIKit identifies as the back button.
    private func backButton(to title: String) -> XCUIElement {
        let titled = app.buttons[title]
        return titled.exists ? titled : app.buttons["BackButton"].firstMatch
    }

    /// Grid photos are accessibility elements named "Photo, <date>".
    private var photos: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
    }

    private var firstPhoto: XCUIElement { photos.firstMatch }

    /// The first photo that lies completely below the navigation bar. The first photo of the grid can sit partly
    /// above it: on the short outer display of iPhone Duo, a tap at its centre reaches the status bar, which scrolls
    /// the grid to the top instead of opening the photo. The grid's photo elements never report `isHittable`, so
    /// their frames decide.
    private func visiblePhoto() -> XCUIElement {
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = app.windows.firstMatch.frame.maxY
        for index in 0..<min(photos.count, 40) {
            let photo = photos.element(boundBy: index)
            if photo.frame.minY >= top, photo.frame.maxY <= bottom {
                return photos.matching(NSPredicate(format: "label == %@", photo.label)).firstMatch
            }
        }
        XCTFail("no photo lies completely in the visible grid")
        return firstPhoto
    }
}
