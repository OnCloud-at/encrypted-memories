import PhotosCore
import PrivacyFeature
import SwiftUI
import TimelineUIKitFeature
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

final class MobileAppProtectionTests: XCTestCase {
    @MainActor func testCancelledAuthenticationKeepsTheWholeSceneCovered() async throws {
        let fixture = try HostFixture(result: .cancelled)
        defer { fixture.close() }
        let cover = try XCTUnwrap(fixture.cover)
        XCTAssertTrue(cover.isOpaque)
        XCTAssertEqual(cover.alpha, 1)
        XCTAssertGreaterThan(cover.windowLevel, .alert)
        XCTAssertEqual(cover.frame, fixture.scene.coordinateSpace.bounds)
        XCTAssertTrue(fixture.source.accessibilityElementsHidden)
        let asked = await yieldUntil { fixture.owner.calls == 1 && !fixture.gate.isAuthenticating }
        XCTAssertTrue(asked)
        XCTAssertFalse(fixture.gate.admits(.app))
        XCTAssertFalse(cover.isHidden)
    }

    @MainActor func testSuccessfulAuthenticationRevealsTheOriginalWindow() async throws {
        let fixture = try HostFixture(result: .success)
        defer { fixture.close() }
        let opened = await yieldUntil {
            fixture.gate.admits(.app) && fixture.cover == nil && !fixture.source.accessibilityElementsHidden
        }
        XCTAssertTrue(opened)
        XCTAssertTrue(fixture.source.isKeyWindow)
    }

    @MainActor func testInactiveSnapshotIsOpaqueEvenWhileTheGateRemainsOpen() async throws {
        let fixture = try HostFixture(result: .success)
        defer { fixture.close() }
        let opened = await yieldUntil { fixture.gate.admits(.app) && fixture.cover == nil }
        XCTAssertTrue(opened)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: fixture.scene)
        let cover = try XCTUnwrap(fixture.cover)
        XCTAssertTrue(fixture.gate.admits(.app), "Inactive alone must not consume the background grace period")
        XCTAssertTrue(cover.isOpaque)
        XCTAssertEqual(cover.alpha, 1)
        XCTAssertTrue(fixture.source.accessibilityElementsHidden)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: fixture.scene)
        XCTAssertNil(fixture.cover)
        XCTAssertFalse(fixture.source.accessibilityElementsHidden)
        XCTAssertEqual(fixture.owner.calls, 1)
    }

    @MainActor func testBackgroundAndReturnRelockBeforeTheActivePrompt() async throws {
        let fixture = try HostFixture(result: .success)
        defer { fixture.close() }
        let opened = await yieldUntil { fixture.gate.admits(.app) && fixture.cover == nil }
        XCTAssertTrue(opened)
        XCTAssertTrue(fixture.gate.setGracePeriod(.zero, for: .app))
        fixture.owner.result = .cancelled
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: fixture.scene)
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: fixture.scene)
        NotificationCenter.default.post(name: UIScene.willEnterForegroundNotification, object: fixture.scene)
        XCTAssertFalse(fixture.gate.admits(.app), "Background expiry must precede the active-phase automatic prompt")
        XCTAssertNotNil(fixture.cover)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: fixture.scene)
        let asked = await yieldUntil { fixture.owner.calls == 2 && !fixture.gate.isAuthenticating }
        XCTAssertTrue(asked, "A new foreground session must ask once")
        XCTAssertFalse(fixture.gate.admits(.app))
        XCTAssertNotNil(fixture.cover)
    }

    @MainActor func testAForegroundSceneWithoutARegisteredWindowExpiresTheGracePeriod() async throws {
        let fixture = try HostFixture(result: .success)
        defer { fixture.close() }
        let opened = await yieldUntil { fixture.gate.admits(.app) && fixture.cover == nil }
        XCTAssertTrue(opened)
        XCTAssertTrue(fixture.gate.setGracePeriod(.zero, for: .app))
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: fixture.scene)
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: fixture.scene)
        // The disconnected scene's entry is gone; a new scene connects before its window registers.
        fixture.center.invalidate()
        let fresh = MobileAppLockCenter(gate: fixture.gate)
        defer { fresh.invalidate() }
        XCTAssertTrue(fixture.gate.admits(.app))
        NotificationCenter.default.post(name: UIScene.willEnterForegroundNotification, object: fixture.scene)
        XCTAssertFalse(fixture.gate.admits(.app), "A returning scene must expire the grace period before it renders")
    }

    @MainActor func testRegisteringAWindowInTheBackgroundKeepsTheBackgroundInterval() async throws {
        let fixture = try HostFixture(result: .success)
        defer { fixture.close() }
        let opened = await yieldUntil { fixture.gate.admits(.app) && fixture.cover == nil }
        XCTAssertTrue(opened)
        XCTAssertTrue(fixture.gate.setGracePeriod(.zero, for: .app))
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: fixture.scene)
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: fixture.scene)
        fixture.center.invalidate()
        let fresh = MobileAppLockCenter(gate: fixture.gate)
        defer { fresh.invalidate() }
        let hosted = HostedTestWindow(scene: fixture.scene)
        defer { hosted.close() }
        fresh.register(window: hosted.window)
        XCTAssertTrue(fixture.gate.admits(.app), "Registering a window of a background scene is not a foreground entry")
        NotificationCenter.default.post(name: UIScene.willEnterForegroundNotification, object: fixture.scene)
        XCTAssertFalse(fixture.gate.admits(.app))
    }

    @MainActor func testAnUnregisteredSceneThatLeavesAgainRestartsTheBackgroundInterval() async throws {
        let fixture = try HostFixture(result: .success)
        defer { fixture.close() }
        let opened = await yieldUntil { fixture.gate.admits(.app) && fixture.cover == nil }
        XCTAssertTrue(opened)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: fixture.scene)
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: fixture.scene)
        fixture.center.invalidate()
        let fresh = MobileAppLockCenter(gate: fixture.gate)
        defer { fresh.invalidate() }
        // An unregistered scene returns within the grace period and leaves before its window registers.
        NotificationCenter.default.post(name: UIScene.willEnterForegroundNotification, object: fixture.scene)
        XCTAssertTrue(fixture.gate.admits(.app), "A return within the grace period keeps the area open")
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: fixture.scene)
        fixture.gate.appWillEnterForeground(at: .now + .seconds(120))
        XCTAssertFalse(fixture.gate.admits(.app), "Leaving again must start a new background interval")
    }

    @MainActor func testActivationAloneExpiresTheGracePeriod() async throws {
        let fixture = try HostFixture(result: .success)
        defer { fixture.close() }
        let opened = await yieldUntil { fixture.gate.admits(.app) && fixture.cover == nil }
        XCTAssertTrue(opened)
        XCTAssertTrue(fixture.gate.setGracePeriod(.zero, for: .app))
        fixture.owner.result = .cancelled
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: fixture.scene)
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: fixture.scene)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: fixture.scene)
        XCTAssertFalse(fixture.gate.admits(.app), "A scene that activates without entering the foreground first locks")
    }

    @MainActor func testASceneWithoutLifecycleEventsUsesItsActivationState() throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let lifecycle = MobilePrivacyPreviewShieldCenter()
        XCTAssertEqual(lifecycle.phase(of: scene), MobileScenePhase.phase(of: scene.activationState))
        XCTAssertEqual(lifecycle.phase(of: scene), .active)
    }

    func testActivationStatesMapToPhases() {
        XCTAssertEqual(MobileScenePhase.phase(of: .foregroundActive), .active)
        XCTAssertEqual(MobileScenePhase.phase(of: .foregroundInactive), .inactive)
        XCTAssertEqual(MobileScenePhase.phase(of: .background), .background, "A scene connecting in the background")
        XCTAssertEqual(MobileScenePhase.phase(of: .unattached), .background)
        XCTAssertEqual(MobileScenePhase.phase(after: UIScene.didDisconnectNotification), nil)
    }

    @MainActor func testAppLockCoversTheContinuedBackupQuestionAcrossWindows() async throws {
        let fixture = try HostFixture(result: .cancelled)
        defer { fixture.close() }
        let probe = MobileContinuedBackupPromptProbe(gate: fixture.gate)
        fixture.source.rootViewController?.view.addSubview(probe.anchorView())
        XCTAssertEqual(probe.presentationsOverPlace(), 0)
        XCTAssertTrue(probe.coversPlace(ownQuestionShows: false), "The separate lock window covers this place")
        fixture.owner.result = .success
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        XCTAssertTrue(fixture.gate.admits(.app))
        XCTAssertFalse(probe.coversPlace(ownQuestionShows: false), "An unlocked place may ask again")
    }

    func testAuthenticationFixtureRequiresTheOfflineAccountAndAKnownResult() {
        let flag = "-EncryptedMemoriesAppLockFixture"
        let offline = MobileUITestLaunch.fixtureArgument
        XCTAssertNil(MobileUITestLaunch.appLockFixtureResult(arguments: [flag, "success"]))
        XCTAssertNil(MobileUITestLaunch.appLockFixtureResult(arguments: [offline, flag]))
        XCTAssertNil(MobileUITestLaunch.appLockFixtureResult(arguments: [offline, flag, "unknown"]))
        for (argument, expected) in [
            ("success", DeviceOwnerAuthResult.success), ("cancelled", .cancelled),
            ("failed", .failed), ("noDeviceLock", .noDeviceLock),
        ] {
            XCTAssertEqual(MobileUITestLaunch.appLockFixtureResult(arguments: [offline, flag, argument]), expected)
        }
    }
}

@MainActor
private final class HostFixture {
    let scene: UIWindowScene
    let source: UIWindow
    private let hosted: HostedTestWindow
    let gate: AccessGate
    let owner: FixtureOwner
    let center: MobileAppLockCenter
    private let defaults: UserDefaults
    private let suite = "MobileAppProtectionTests.\(UUID().uuidString)"

    var cover: UIWindow? {
        scene.windows.first { !$0.isHidden && $0.windowLevel.rawValue == UIWindow.Level.alert.rawValue + 2 }
    }

    init(result: DeviceOwnerAuthResult) throws {
        scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        owner = FixtureOwner(result: result)
        gate = AccessGate(authenticator: owner, defaults: defaults)
        center = MobileAppLockCenter(gate: gate)
        hosted = HostedTestWindow(scene: scene)
        source = hosted.window
        source.rootViewController = UIHostingController(rootView: Color.red)
        source.makeKeyAndVisible()
        center.register(window: source)
    }

    func close() {
        center.invalidate()
        hosted.close()
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class FixtureOwner: DeviceOwnerAuthenticating {
    var result: DeviceOwnerAuthResult
    private(set) var calls = 0
    init(result: DeviceOwnerAuthResult) { self.result = result }
    func availability() -> DeviceOwnerAuthAvailability { .available(.faceID) }
    func authenticate(reason: String) async -> DeviceOwnerAuthResult {
        calls += 1
        return result
    }
    func cancel() {}
}
