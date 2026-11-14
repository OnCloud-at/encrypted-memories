import XCTest

final class MobileAppLockUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
    }

    override func tearDown() {
        app.terminate()
    }

    func testPrivacySwitchEnablesAppLock() {
        launch(result: "success")
        waitForLibrary()
        app.buttons["Proton Account and Settings"].tap()
        let privacy = app.buttons["Privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        privacy.tap()
        XCTAssertTrue(app.switches["Blur App Preview"].waitForExistence(timeout: 5))
        let protection = app.switches["Require Face ID"]
        XCTAssertTrue(protection.waitForExistence(timeout: 5), "Privacy must offer the optional app lock")
        protection.tap()
        XCTAssertEqual(protection.wait(until: "value == '1'", timeout: 5), .completed)
        let delay = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Lock After")).firstMatch
        XCTAssertTrue(delay.waitForExistence(timeout: 5))
        delay.tap()
        let immediately = app.buttons["Immediately"]
        XCTAssertTrue(immediately.waitForExistence(timeout: 5))
        immediately.tap()
        let privacyBack = app.navigationBars.buttons["Privacy"]
        if privacyBack.exists { privacyBack.tap() }
        XCTAssertTrue(protection.waitForExistence(timeout: 5))
        protection.tap()
        XCTAssertEqual(protection.wait(until: "value == '0'", timeout: 5), .completed)
        XCTAssertFalse(delay.exists)
        attachScreenshot("Privacy app lock")
    }

    func testSuccessfulLaunchAuthenticationRevealsTheLibrary() {
        launch(result: "success", enabled: true)
        waitForLibrary()
        XCTAssertFalse(app.buttons["Unlock with Face ID"].exists)
    }

    func testCancelledAuthenticationKeepsTheCoverAndManualUnlockButton() {
        assertCovered(result: "cancelled")
    }

    func testFailedAuthenticationKeepsTheCoverAndManualUnlockButton() {
        assertCovered(result: "failed")
    }

    func testWithoutADevicePasscodeTheSwitchIsDisabled() {
        launch(result: "noDeviceLock")
        waitForLibrary()
        app.buttons["Proton Account and Settings"].tap()
        app.buttons["Privacy"].tap()
        let protection = app.switches["Require Passcode"]
        XCTAssertTrue(protection.waitForExistence(timeout: 5))
        XCTAssertFalse(protection.isEnabled)
    }

    private func launch(result: String, enabled: Bool = false) {
        app.launchArguments += [
            "-EncryptedMemoriesUITestFixture",
            "-EncryptedMemoriesAppLockFixture", result,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if enabled { app.launchArguments.append("-EncryptedMemoriesAppLockInitiallyEnabled") }
        app.launch()
    }

    private func waitForLibrary() {
        XCTAssertTrue(photo.waitForExistence(timeout: 60), "The offline library must be ready")
    }

    private var photo: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo, ")).firstMatch
    }

    private func assertCovered(result: String) {
        launch(result: result, enabled: true)
        let unlock = app.buttons["Unlock with Face ID"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 30))
        XCTAssertEqual(unlock.wait(until: "enabled == true", timeout: 5), .completed)
        XCTAssertFalse(photo.exists, "Covered library controls must not be exposed")
        unlock.tap()
        XCTAssertEqual(unlock.wait(until: "enabled == true", timeout: 5), .completed)
        XCTAssertTrue(unlock.exists)
        XCTAssertFalse(photo.exists)
        attachScreenshot("Locked after " + result)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
