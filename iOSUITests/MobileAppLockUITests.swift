import XCTest

final class MobileAppLockUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
        app.launchArguments += [
            "-EncryptedMemoriesUITestFixture",
            "-EncryptedMemoriesAppLockFixture", "success",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    func testPrivacySwitchEnablesAppLock() {
        let photo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo, ")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 60), "The offline library must be ready")
        app.buttons["Proton Account and Settings"].tap()
        let privacy = app.buttons["Privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        privacy.tap()
        XCTAssertTrue(app.switches["Blur App Preview"].waitForExistence(timeout: 5))

        let protection = app.switches.matching(
            NSPredicate(format: "label IN %@", ["Require Face ID", "Require Touch ID", "Require Passcode"])
        ).firstMatch
        XCTAssertTrue(protection.waitForExistence(timeout: 5), "Privacy must offer the optional app lock")
        protection.tap()
        XCTAssertEqual(protection.wait(until: "value == '1'", timeout: 5), .completed)
    }
}
