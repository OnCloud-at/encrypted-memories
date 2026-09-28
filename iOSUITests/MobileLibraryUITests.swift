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
        firstPhoto.tap()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer did not open")
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

    /// A video plays under its controls with the filmstrip below, and the same player keeps playing when the chrome
    /// hides and returns. On iPhone Duo the viewer arranges media and filmstrip with an arrangement view.
    func testAVideoKeepsPlayingWhileTheViewerChromeToggles() {
        app.terminate()
        app.launchArguments.append("-EncryptedMemoriesUITestVideo")
        app.launch()
        let video = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Video, '"))
            .firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 60), "the library shows no video")
        // The leading part of the tile stays clear of a vertical bar on the trailing edge.
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()

        let position = app.sliders["Video position"]
        XCTAssertTrue(position.waitForExistence(timeout: 20), "the video shows no playback controls")
        XCTAssertTrue(app.collectionViews["Photo library grid"].exists, "the viewer shows no filmstrip")
        XCTAssertTrue(waitForElapsed(of: position, atLeast: 3, timeout: 10), "the video does not play")

        // One tap hides the chrome, the next brings it back. The 8-second video keeps its position in between: a
        // restarted player would show less than the 3 seconds already played.
        let media = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4))
        let beforeHiding = elapsedSeconds(of: position) ?? 0
        media.tap()
        XCTAssertTrue(wait(for: position, "exists == false"), "the chrome does not hide")
        media.tap()
        XCTAssertTrue(position.waitForExistence(timeout: 5), "the chrome does not return")
        XCTAssertGreaterThanOrEqual(elapsedSeconds(of: position) ?? 0, beforeHiding, "playback started over")
        XCTAssertTrue(
            waitForElapsed(of: position, atLeast: beforeHiding + 1, timeout: 4), "playback did not continue")
    }

    /// The whole seconds already played, from the position value "m:ss / m:ss".
    private func elapsedSeconds(of slider: XCUIElement) -> Int? {
        guard let value = slider.value as? String, let elapsed = value.split(separator: "/").first else { return nil }
        let parts = elapsed.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    private func waitForElapsed(of slider: XCUIElement, atLeast seconds: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let elapsed = elapsedSeconds(of: slider), elapsed >= seconds { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
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
