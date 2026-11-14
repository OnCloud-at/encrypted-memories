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

    func testTheDisabledSwitchNamesTheDevicePasscode() {
        XCTAssertEqual(
            AppLockCopy.switchTitle(for: .noDeviceLock),
            AppLockCopy.switchTitle(for: .available(.devicePasscode)))
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
        source = UIWindow(windowScene: scene)
        source.rootViewController = UIHostingController(rootView: Color.red)
        source.makeKeyAndVisible()
        center.register(window: source)
    }

    func close() {
        center.invalidate()
        source.isHidden = true
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class FixtureOwner: DeviceOwnerAuthenticating {
    private let result: DeviceOwnerAuthResult
    private(set) var calls = 0
    init(result: DeviceOwnerAuthResult) { self.result = result }
    func availability() -> DeviceOwnerAuthAvailability { .available(.faceID) }
    func authenticate(reason: String) async -> DeviceOwnerAuthResult {
        calls += 1
        return result
    }
    func cancel() {}
}
