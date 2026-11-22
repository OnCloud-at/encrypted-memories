import XCTest

/// A video that cannot play shows its failure card. In iPhone landscape the card is taller than the page and scrolls:
/// a pan on it scrolls the card and never closes the viewer, and Close stays visible as the way out. A card that fits
/// keeps the swipe down that closes the viewer. The app runs in German, whose longer texts make the card taller, and
/// with the video failure scenario: the first changeable failure offers Try again, the next one is final.
final class MobilePlaybackFailedUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
        app.launchArguments += [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesVideoFailureScenario",
            "-AppleLanguages", "(de)", "-AppleLocale", "de_DE",
        ]
        if name.contains("LargestText") {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        // A teardown block also runs after a failed assertion, so later tests never start in landscape.
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
    }

    override func tearDown() {
        app.terminate()
    }

    func testAPanScrollsTheFailureCardInLandscape() throws {
        try panScrollsTheCardAndTryAgainWorks()
    }

    func testAPanScrollsTheFailureCardInLandscapeAtTheLargestTextSize() throws {
        try panScrollsTheCardAndTryAgainWorks()
    }

    /// The person hid the chrome on a photo and pages to the failed video: Close shows again. Back on the photo, the
    /// chrome is hidden again as the person chose; on the video once more, Close closes the viewer. The failed video
    /// is the last page; paging uses a drag across the page, which the page of a scrolling card leaves to the pager,
    /// so each drag waits until the card scrolls.
    func testCloseShowsWhenTheVideoFailsWithTheChromeHiddenAtTheLargestTextSize() throws {
        openTheFailedVideo()
        try turn(to: .landscapeLeft)
        XCTAssertTrue(scroll.waitForExistence(timeout: 10), "SETUP: the card must scroll in landscape")
        page(by: 0.7)
        XCTAssertTrue(position("216 von 217").waitForExistence(timeout: 5), "SETUP: the photo page did not open")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(
            close.wait(until: "hittable == false", timeout: 5), .completed, "SETUP: a tap did not hide the chrome")

        page(by: -0.7)
        // The page prepares the video again; the final failure, not the earlier card, ends that.
        let finalCard = app.scrollViews.containing(
            NSPredicate(format: "label == %@", "Das Video konnte nicht entschlüsselt werden.")
        ).firstMatch
        XCTAssertTrue(finalCard.waitForExistence(timeout: 30), "no scrolling final failure card")
        XCTAssertEqual(close.wait(until: "hittable == true", timeout: 5), .completed, "Close is hidden on the failure")
        attach(named: "Failure with the chrome forced")

        // On the photo the bars, and with them its position, are hidden again; only the failure page forces Close.
        page(by: 0.7)
        XCTAssertEqual(
            close.wait(until: "hittable == false", timeout: 5), .completed, "the chosen hidden chrome did not return")
        page(by: -0.7)
        XCTAssertEqual(close.wait(until: "hittable == true", timeout: 5), .completed, "Close is hidden on the failure")
        close.tap()
        XCTAssertTrue(video.waitForExistence(timeout: 10), "Close did not close the viewer")
    }

    /// A drag below the closing distance springs the page back, and the next swipe down still closes the viewer.
    func testASmallDragSpringsBackAndTheNextSwipeCloses() throws {
        openTheFailedVideo()
        let rest = tryAgain.frame
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 50)), withVelocity: .slow,
            thenHoldForDuration: 0.1)
        XCTAssertEqual(close.waitUntilGone(timeout: 2), .timedOut, "a small drag closed the viewer")
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.tryAgain.frame == rest }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [returned], timeout: 3), .completed,
            "the page did not spring back: \(tryAgain.frame), at rest \(rest)")

        swipeDownToClose()
    }

    /// After the card scrolled in landscape, the device turns to portrait, where the card fits: a swipe down closes.
    func testASwipeClosesInPortraitAfterTheCardScrolledInLandscape() throws {
        openTheFailedVideo()
        try turn(to: .landscapeLeft)
        swipeToTheEnd(of: scroll)
        try turn(to: .portrait)
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 5))
        swipeDownToClose()
    }

    private var video: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Video, '")).firstMatch
    }

    private var close: XCUIElement { app.buttons["Schließen"] }
    private var tryAgain: XCUIElement { app.buttons["Erneut versuchen"] }
    private var scroll: XCUIElement {
        app.scrollViews.containing(NSPredicate(format: "label == %@", "Erneut versuchen")).firstMatch
    }

    private func position(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    /// Drags across the page by `fraction` of the window width: positive to the previous page, negative to the next.
    private func page(by fraction: CGFloat) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: fraction > 0 ? 0.2 : 0.9, dy: 0.5))
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: window.frame.width * fraction, dy: 0)),
            withVelocity: .default, thenHoldForDuration: 0)
    }

    private func openTheFailedVideo() {
        XCTAssertTrue(video.waitForExistence(timeout: 60), "the library grid shows no video")
        video.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer did not open")
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 30), "the changeable failure offers no Try again")
    }

    /// Turns the window. The simulator of the iPhone Duo starts on its outer display, which keeps its portrait window
    /// when the device turns: the window stayed 466 x 678 points for 20 seconds after landscape left, landscape right
    /// and upside down alike (probe on iOS 27.1). A landscape layout cannot be reached there, so the test skips with
    /// that reason, only on the Duo model. On every other device a window that does not turn still fails the test.
    private func turn(to orientation: UIDeviceOrientation) throws {
        let turned = app.turnWindow(to: orientation)
        if !turned, orientation.isLandscape, UITestApplication.runsOnIPhoneDuo {
            let size = app.windows.firstMatch.frame.size
            throw XCTSkip(
                "iPhone Duo outer display: the window stayed \(size) after the device turned to \(orientation.rawValue); "
                    + "a landscape layout needs the inner display (manual check, open or book pose)")
        }
        XCTAssertTrue(turned, "the window did not turn")
    }

    private func swipeDownToClose() {
        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 400)))
        XCTAssertEqual(close.waitUntilGone(timeout: 20), .completed, "swiping down did not close the viewer")
    }

    private func panScrollsTheCardAndTryAgainWorks() throws {
        openTheFailedVideo()
        try turn(to: .landscapeLeft)
        XCTAssertTrue(scroll.waitForExistence(timeout: 10), "SETUP: the card must scroll in landscape")
        attach(named: "Landscape top")

        // Swipe up on the card until its end shows.
        swipeToTheEnd(of: scroll)
        attach(named: "Landscape bottom end")
        XCTAssertTrue(close.exists, "a swipe up on the card closed the viewer")
        XCTAssertTrue(scroll.frame.contains(tryAgain.frame), "Try again is not fully on the page")

        // A pan back down scrolls the card and leaves the viewer open.
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 60)), withVelocity: .fast,
            thenHoldForDuration: 0)
        XCTAssertEqual(close.waitUntilGone(timeout: 3), .timedOut, "a pan down on the card closed the viewer")
        XCTAssertTrue(tryAgain.exists, "a pan down on the card removed the failure")

        swipeToTheEnd(of: scroll)
        tryAgain.tap()
        XCTAssertTrue(
            app.staticTexts["Das Video konnte nicht entschlüsselt werden."].waitForExistence(timeout: 20),
            "Try again did not prepare the video again")
        XCTAssertFalse(tryAgain.exists, "the final failure still offers Try again")
        try turn(to: .portrait)
        attach(named: "Portrait final failure")
    }

    /// Swipes up until Try again is hittable with the card's padding (24 points) and margin (16 points) below it.
    private func swipeToTheEnd(of scroll: XCUIElement) {
        func showsTheEnd() -> Bool {
            tryAgain.isHittable && scroll.frame.maxY - tryAgain.frame.maxY >= 40
        }
        var swipes = 0
        while !showsTheEnd(), swipes < 6 {
            scroll.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(
            showsTheEnd(),
            "the end of the card does not show: page \(scroll.frame), Try again \(tryAgain.frame)")
    }

    private func attach(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
