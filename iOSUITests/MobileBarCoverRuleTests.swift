import XCTest

/// The cover check of `tapOnScreen(_:)`: every real bar covers content, the window-sized toolbar container of iOS 27
/// covers nothing.
@MainActor
final class MobileBarCoverRuleTests: XCTestCase {
    func testWindowSizedToolbarContainersCoverNothing() {
        // The container frames that iOS 27.0 reports on iPhone 17 and on iPad Pro 13-inch (M5).
        for window in [CGRect(x: 0, y: 0, width: 402, height: 874), CGRect(x: 0, y: 0, width: 1032, height: 1376)] {
            XCTAssertFalse(barCoversContent(window, in: window), "\(window)")
        }
    }

    func testHorizontalBarsCoverContent() {
        // The navigation bar and the tab bar that iOS 27.0 reports on iPhone 17.
        let window = CGRect(x: 0, y: 0, width: 402, height: 874)
        XCTAssertTrue(barCoversContent(CGRect(x: 0, y: 62, width: 402, height: 54), in: window))
        XCTAssertTrue(barCoversContent(CGRect(x: 0, y: 791, width: 402, height: 83), in: window))
    }

    /// The vertical tab bar of iPhone Duo is as tall as the window but narrow. It covers the content beside it, so a
    /// row under it is not tapped, and a row beside it is.
    func testTheVerticalBarOfIPhoneDuoCoversContent() throws {
        let app = UITestApplication.make()
        app.launchArguments += ["-EncryptedMemoriesUITestFixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        guard try app.verticalTabColumn() != nil else {
            throw XCTSkip("This check requires the system to present the tabs vertically")
        }
        let window = app.windows.firstMatch.frame
        let strip = try XCTUnwrap(app.verticalTabStrip(), "The vertical tab bar has a strip")
        print("[Vertical bar cover] window=\(window) strip=\(strip)")
        XCTAssertLessThan(strip.width, window.width / 4, "The vertical bar \(strip) is narrow")
        XCTAssertEqual(strip.height, window.height, "The vertical bar spans the window")
        XCTAssertTrue(barCoversContent(strip, in: window), "The vertical bar \(strip) covers content")
        let content = strip.minX > window.midX ? window.minX : strip.maxX
        let row = CGRect(x: content + 8, y: window.midY, width: 40, height: 40)
        let under = CGRect(x: strip.midX - 20, y: window.midY, width: 40, height: 40)
        XCTAssertTrue(app.liesOnScreenClearOfBars(row), "A row beside the vertical bar can be tapped")
        XCTAssertFalse(app.liesOnScreenClearOfBars(under), "A row under the vertical bar is not tapped")
    }
}
