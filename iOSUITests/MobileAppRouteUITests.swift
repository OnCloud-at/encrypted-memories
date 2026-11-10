import XCTest

/// Links with the app's own scheme open places in the app on the offline fixture account. A link only navigates;
/// an unknown or malformed link changes nothing and shows no message.
final class MobileAppRouteUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
        app.launchArguments += ["-EncryptedMemoriesUITestFixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.firstPhoto.waitForExistence(timeout: 60), "the fixture library did not load")
    }

    override func tearDown() { app.terminate() }

    func testACollectionLinkOpensTheCollection() throws {
        try open("encryptedmemories://collection/favorites")
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 20), "Favorites did not open")
    }

    func testALibraryLinkReturnsToTheLibrary() throws {
        openCollectionsTab()
        try open("encryptedmemories://library")
        XCTAssertEqual(
            app.navigationBars["Collections"].waitUntilGone(timeout: 20), .completed, "the library did not open")
        XCTAssertTrue(app.firstPhoto.waitForExistence(timeout: 10))
    }

    func testACollectionLinkReplacesAScreenOpenedInCollections() throws {
        openCollectionsTab()
        app.openRecentlyDeleted()
        XCTAssertTrue(app.navigationBars["Recently Deleted"].waitForExistence(timeout: 10))

        try open("encryptedmemories://collection/videos")
        XCTAssertTrue(app.navigationBars["Videos"].waitForExistence(timeout: 20), "Videos did not open")
    }

    func testUnknownAndMalformedLinksChangeNothing() throws {
        openCollectionsTab()
        for link in [
            "encryptedmemories://settings", "encryptedmemories://album/x", "encryptedmemories://collection/Favorites",
            "encryptedmemories://collection/favorites?x=1", "encryptedmemories:library",
        ] {
            try open(link)
            XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 5), link)
            XCTAssertFalse(app.navigationBars["Favorites"].exists, link)
            XCTAssertEqual(app.alerts.count, 0, link)
        }
    }

    func testALinkWaitsWhileSettingsIsOpen() throws {
        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))

        try open("encryptedmemories://collection/favorites")
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the link must not close Settings")
        XCTAssertFalse(app.navigationBars["Favorites"].exists, "the link opened behind Settings")

        done.tap()
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 20), "Favorites did not open after")
    }

    func testALinkWaitsWhileThePhotoViewerIsOpen() throws {
        app.firstPhoto.tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer did not open")

        try open("encryptedmemories://collection/favorites")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the link must not close the viewer")
        XCTAssertFalse(app.navigationBars["Favorites"].exists, "the link opened behind the viewer")

        close.tap()
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 20), "Favorites did not open after")
    }

    /// Opens `link` through the system, like another app does, so the running app receives it. (`app.open(_:)`
    /// launches the app anew and would lose its state.) The system may ask once whether to open the app.
    private func open(_ link: String) throws {
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: link)))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirm = springboard.buttons["Open"]
        if confirm.waitForExistence(timeout: 2) { confirm.tap() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    private func openCollectionsTab() {
        let collections = app.tab(titled: "Collections")
        XCTAssertTrue(collections.waitForExistence(timeout: 20))
        collections.tap()
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 10))
    }
}
