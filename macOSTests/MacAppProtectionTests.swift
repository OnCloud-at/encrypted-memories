import AppKit
import PhotosCore
import PrivacyFeature
import SwiftUI
import XCTest

@MainActor
final class MacAppProtectionTests: XCTestCase {
    func testTheOpaqueChildCoversTheCompleteWindow() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let cover = try XCTUnwrap(fixture.cover)
        XCTAssertTrue(cover.isOpaque)
        XCTAssertEqual(cover.alphaValue, 1)
        XCTAssertEqual(cover.frame, fixture.window.frame)
        XCTAssertEqual(cover.level, fixture.window.level)
        XCTAssertTrue(cover.worksWhenModal)
    }

    func testSuccessfulAuthenticationRevealsOnlyAnActiveWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        let settled = await fixture.waitForCover(visible: false)
        XCTAssertTrue(settled)
        XCTAssertFalse(fixture.presentation.snapshot)
        XCTAssertTrue(fixture.gate.admits(.app))
    }

    func testApplicationDeactivationDoesNotStartTheBackgroundGracePeriod() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        fixture.gate.appWillEnterForeground(at: .now + .seconds(120))
        XCTAssertTrue(fixture.gate.admits(.app))
    }

    func testScreenSleepRelocksAndCoversTheWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        let settled = await fixture.waitForCover(visible: false)
        XCTAssertTrue(settled)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertFalse(fixture.gate.admits(.app))
        XCTAssertNotNil(fixture.cover)
    }

    func testOrderingOutTheLastWindowStartsTheBackgroundGracePeriod() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        fixture.window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: fixture.window)
        fixture.gate.appWillEnterForeground(at: .now + .seconds(120))
        XCTAssertFalse(fixture.gate.admits(.app))
    }
    func testOrderingOutRetainsTheSnapshotCoverBeforeTheWindowReturns() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        _ = await fixture.waitForCover(visible: false)
        fixture.window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: fixture.window)
        XCTAssertTrue(fixture.window.childWindows?.contains { $0 is MacAppLockPanel } == true)
        fixture.gate.appWillEnterForeground(at: .now + .seconds(120))
        fixture.window.orderFront(nil)
        XCTAssertNotNil(fixture.cover, "The returning window must already be covered in this turn")
    }

    func testTheCoverIsAttachedBeforeMiniaturizationBegins() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        _ = await fixture.waitForCover(visible: false)
        NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: fixture.window)
        XCTAssertNotNil(fixture.cover, "The cover must precede the minimized Dock snapshot")
        XCTAssertTrue(fixture.window.childWindows?.contains { $0 is MacAppLockPanel } == true)
    }
    func testPrepareToShowExpiresAdmissionBeforeOrderingTheWindowIn() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        XCTAssertTrue(fixture.gate.setGracePeriod(.zero, for: .app))
        fixture.controller.prepareToHide(window: fixture.window)
        fixture.window.orderOut(nil)
        fixture.controller.prepareToShow(window: fixture.window)
        XCTAssertFalse(fixture.gate.admits(.app), "Expiry must be applied while the source is still hidden")
        fixture.window.orderFront(nil)
        XCTAssertNotNil(fixture.cover, "The first returning frame must already have the cover attached")
    }

    func testRegisteringAnotherHiddenWindowPreservesTheBackgroundInterval() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        fixture.controller.prepareToHide(window: fixture.window)
        fixture.window.orderOut(nil)
        let other = NSWindow(
            contentRect: .init(x: -10_000, y: -10_000, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        fixture.controller.register(window: other)
        fixture.gate.appWillEnterForeground(at: .now + .seconds(120))
        XCTAssertFalse(fixture.gate.admits(.app), "Registering a hidden window is not a foreground entry")
    }

    func testClosingAndReopeningTheSameWindowRetainsProtectionWithoutReregistration() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        let revealed = await fixture.waitForCover(visible: false)
        XCTAssertTrue(revealed)
        XCTAssertTrue(fixture.gate.setGracePeriod(.zero, for: .app))
        fixture.window.close()
        XCTAssertTrue(fixture.presentation.snapshot, "Closing a cached Settings window must retain coverage")
        fixture.window.orderFront(nil)
        XCTAssertEqual(try fixture.redSamples(), 0, "Reopening must not draw the stored settings before key handling")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        XCTAssertFalse(fixture.gate.admits(.app), "A reused window must still belong to the protection host")
        XCTAssertNotNil(fixture.cover)
    }

    func testAnInactiveWindowKeepsItsSnapshotUntilItBecomesActive() async throws {
        let fixture = try Fixture(active: false)
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        let covered = await fixture.waitForCover(visible: true)
        XCTAssertTrue(covered)
        XCTAssertTrue(fixture.presentation.snapshot)
        fixture.activity.isActive = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        let revealed = await fixture.waitForCover(visible: false)
        XCTAssertTrue(revealed)
        XCTAssertFalse(fixture.presentation.snapshot)
        XCTAssertTrue(fixture.gate.admits(.app))
    }

    func testNativeReturnNotificationsExpireAdmissionBeforeUncovering() async throws {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
            let fixture = try Fixture()
            defer { fixture.close() }
            _ = await fixture.gate.unlock(.app, reason: "Unlock")
            XCTAssertTrue(fixture.gate.setGracePeriod(.zero, for: .app))
            fixture.gate.appDidEnterBackground(at: .now)
            NotificationCenter.default.post(name: name, object: fixture.window)
            XCTAssertFalse(fixture.gate.admits(.app), "The native return callback must apply expiry")
            XCTAssertNotNil(fixture.cover)
        }
    }

    func testNativeReturnNotificationsReleaseTheSuspendedSnapshotWithinGrace() async throws {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
            let fixture = try Fixture()
            defer { fixture.close() }
            _ = await fixture.gate.unlock(.app, reason: "Unlock")
            fixture.controller.prepareToHide(window: fixture.window)
            XCTAssertTrue(fixture.presentation.snapshot)
            NotificationCenter.default.post(name: name, object: fixture.window)
            XCTAssertFalse(fixture.presentation.snapshot, "A foreground return within grace must reveal the source")
            XCTAssertNil(fixture.cover)
        }
    }

    func testWillHideCoversTheStillVisibleSourceBeforeAppKitHidesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        let revealed = await fixture.waitForCover(visible: false)
        XCTAssertTrue(revealed)
        XCTAssertGreaterThan(try fixture.redSamples(), 0)
        NotificationCenter.default.post(name: NSApplication.willHideNotification, object: NSApp)
        XCTAssertTrue(fixture.presentation.snapshot)
        XCTAssertNotNil(fixture.cover)
        XCTAssertEqual(try fixture.redSamples(), 0)
        NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: NSApp)
        XCTAssertFalse(fixture.presentation.snapshot)
    }

    func testTheDefaultActivityQueryUsesTheApplicationActivity() async throws {
        let fixture = try Fixture(useSystemActivity: true)
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(fixture.presentation.snapshot, !NSApp.isActive)
    }

    func testClosingAChildKeepsItsSuspendedRootCovered() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        fixture.controller.prepareToHide(window: fixture.window)
        let child = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 80, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        fixture.window.addChildWindow(child, ordered: .above)
        child.close()
        XCTAssertTrue(fixture.presentation.snapshot)
        XCTAssertNotNil(fixture.cover)
        XCTAssertTrue(fixture.window.childWindows?.contains { $0 is MacAppLockPanel } == true)
        fixture.window.removeChildWindow(child)
    }

    func testRefreshPrunesSuspensionEntriesOfDeallocatedRoots() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.setEnabled(false, for: .app, reason: "Confirm")
        weak var released: NSWindow?
        var identifier: ObjectIdentifier?
        autoreleasepool {
            let window = NSWindow(
                contentRect: .init(x: -10_000, y: -10_000, width: 80, height: 80),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            released = window
            identifier = ObjectIdentifier(window)
            fixture.controller.register(window: window)
            fixture.controller.prepareToHide(window: window)
            window.close()
        }
        XCTAssertNil(released, "The root must deallocate for the lifetime control to be valid")
        fixture.controller.register(window: fixture.window)
        let entries = try XCTUnwrap(
            Mirror(reflecting: fixture.controller).children.first { $0.label == "suspending" }?.value
                as? Set<ObjectIdentifier>)
        XCTAssertFalse(entries.contains(try XCTUnwrap(identifier)), "Refresh must release stale suspension identities")
    }

    func testSnapshotDrawsInsideTheSourceBeforeMiniaturization() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        fixture.presentation.snapshot = false
        XCTAssertGreaterThan(try fixture.redSamples(), 0, "The uncovered source must provide a pixel positive control")
        NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: fixture.window)
        XCTAssertTrue(fixture.presentation.snapshot)
        XCTAssertEqual(try fixture.redSamples(), 0, "The source itself must conceal the photo before the Dock capture")
    }
}

@MainActor
private final class Fixture {
    let window: NSWindow
    let gate: AccessGate
    let controller: MacAppProtection
    let presentation: ProtectedScopePresentation
    let activity: Activity
    private let defaults: UserDefaults
    private let suite = "MacAppProtectionTests.\(UUID().uuidString)"

    var cover: NSPanel? { window.childWindows?.compactMap { $0 as? NSPanel }.first { $0.isVisible } }

    init(active: Bool = true, useSystemActivity: Bool = false) throws {
        _ = NSApplication.shared
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        gate = AccessGate(authenticator: Owner(), defaults: defaults)
        activity = Activity(active: active)
        let activity = activity
        if useSystemActivity {
            controller = MacAppProtection(gate: gate)
        } else {
            controller = MacAppProtection(gate: gate, applicationIsActive: { activity.isActive })
        }
        presentation = ProtectedScopePresentation(gate: gate)
        window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 320, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SourceContent(presentation: presentation))
        window.orderFront(nil)
        controller.register(window: window, presentation: presentation)
    }

    func redSamples() throws -> Int {
        let view = try XCTUnwrap(window.contentView)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return stride(from: 0, to: bitmap.pixelsHigh, by: 8).reduce(0) { count, y in
            count
                + stride(from: 0, to: bitmap.pixelsWide, by: 8).filter { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.5 && color.redComponent > color.greenComponent * 2
                        && color.redComponent > color.blueComponent * 2
                }.count
        }
    }

    func waitForCover(visible: Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if (cover != nil) == visible { return true }
            await Task.yield()
        }
        return (cover != nil) == visible
    }

    func close() {
        controller.invalidate()
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class Owner: DeviceOwnerAuthenticating {
    func availability() -> DeviceOwnerAuthAvailability { .available(.touchID) }
    func authenticate(reason: String) async -> DeviceOwnerAuthResult { .success }
    func cancel() {}
}

private struct SourceContent: View {
    let presentation: ProtectedScopePresentation
    var body: some View {
        Color(red: 1, green: 0, blue: 0).protectedScope(
            .app, gate: presentation.gate, unlockTitle: "Unlock", accessibilityLabel: "Locked", reason: "Unlock",
            snapshot: presentation.snapshot
        )
        .environment(\.scenePhase, presentation.phase)
    }
}

@MainActor
private final class Activity {
    var isActive: Bool
    init(active: Bool) { isActive = active }
}
