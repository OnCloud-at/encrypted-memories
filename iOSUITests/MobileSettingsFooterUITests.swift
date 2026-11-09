import XCTest

@MainActor
final class MobileSettingsFooterUITests: XCTestCase {
    func testSettingsFooterShowsBuildAndAttribution() {
        let app = UITestApplication.make()
        app.launchArguments += ["-EncryptedMemoriesUITestFixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }

        let settings = app.buttons["Proton Account and Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        let versions = app.links.matching(NSPredicate(format: "label BEGINSWITH 'Version '"))
        let commits = app.links.matching(NSPredicate(format: "label MATCHES '[0-9a-f]{7}'"))
        let version = versions.firstMatch
        let commit = commits.firstMatch
        let attribution = app.staticTexts["Made with ❤️ in Austria 🇦🇹"]
        for _ in 0..<6 where !attribution.isHittable { app.swipeUp() }
        XCTAssertTrue(version.waitForExistence(timeout: 10))
        XCTAssertTrue(attribution.waitForExistence(timeout: 10))
        XCTAssertEqual(versions.count, 1)
        if commit.exists { XCTAssertEqual(commits.count, 1) }
        let dots = app.staticTexts.matching(NSPredicate(format: "label == '·' OR identifier == '·'"))
        XCTAssertEqual(dots.count, 0, "Decorative separators are hidden")
        let ordered = commit.exists ? [version, commit, attribution] : [version, attribution]
        for (first, second) in zip(ordered, ordered.dropFirst()) {
            let leftToRight = abs(first.frame.midY - second.frame.midY) < 3 && first.frame.minX < second.frame.minX
            XCTAssertTrue(leftToRight || first.frame.midY + 3 < second.frame.midY, "Footer elements keep reading order")
        }
        if app.windows.firstMatch.frame.width >= 700 {
            XCTAssertEqual(version.frame.midY, attribution.frame.midY, accuracy: 3, "The wide footer fits on one line")
        }
    }
}
