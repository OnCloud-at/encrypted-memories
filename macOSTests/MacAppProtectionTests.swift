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

    func testSuccessfulAuthenticationRevealsAVisibleWindowOfAnInactiveApp() async throws {
        let activity = Activity(active: false)
        let fixture = try Fixture(applicationIsActive: { activity.isActive })
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        let revealed = await fixture.waitForCover(visible: false)
        XCTAssertTrue(revealed)
        XCTAssertFalse(fixture.presentation.snapshot)
        XCTAssertEqual(fixture.presentation.phase, .inactive)
        XCTAssertTrue(fixture.gate.admits(.app))
        activity.isActive = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        let stillRevealed = await fixture.waitForCover(visible: false)
        XCTAssertTrue(stillRevealed)
        XCTAssertEqual(fixture.presentation.phase, .active)
        XCTAssertTrue(fixture.gate.admits(.app))
    }

    func testALockedWindowOfAnInactiveAppDoesNotPromptAutomatically() async throws {
        let fixture = try Fixture(applicationIsActive: { false })
        defer { fixture.close() }
        XCTAssertNotNil(fixture.cover)
        for _ in 0..<200 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.owner.calls, 0, "The system dialog must not appear over another app")
        XCTAssertFalse(fixture.gate.admits(.app))
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
        let other = makeWindow(size: .init(width: 100, height: 100))
        defer { other.close() }
        fixture.controller.register(window: other)
        fixture.gate.appWillEnterForeground(at: .now + .seconds(120))
        XCTAssertFalse(fixture.gate.admits(.app), "Registering a hidden window is not a foreground entry")
    }

    func testUnhidingWithoutAReturningWindowPreservesTheBackgroundInterval() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        fixture.controller.prepareToHide(window: fixture.window)
        fixture.window.orderOut(nil)
        NotificationCenter.default.post(name: NSApplication.willUnhideNotification, object: NSApp)
        fixture.gate.appWillEnterForeground(at: .now + .seconds(120))
        XCTAssertFalse(fixture.gate.admits(.app), "Unhide without a protected window must preserve expiry")
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
        let fixture = try Fixture(applicationIsActive: nil)
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(fixture.presentation.phase, NSApp.isActive ? .active : .inactive)
        XCTAssertFalse(fixture.presentation.snapshot)
    }

    func testClosingAChildKeepsItsSuspendedRootCovered() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        fixture.controller.prepareToHide(window: fixture.window)
        let child = makeWindow()
        fixture.window.addChildWindow(child, ordered: .above)
        child.close()
        XCTAssertTrue(fixture.presentation.snapshot)
        XCTAssertNotNil(fixture.cover)
        XCTAssertTrue(fixture.window.childWindows?.contains { $0 is MacAppLockPanel } == true)
        fixture.window.removeChildWindow(child)
    }

    func testSuspensionBelongsToTheWeakRootAndCannotReachANewRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.setEnabled(false, for: .app, reason: "Confirm")
        weak var released: NSWindow?
        try autoreleasepool {
            let window = makeWindow()
            released = window
            fixture.controller.register(window: window)
            fixture.controller.prepareToHide(window: window)
            XCTAssertEqual(try suspension(of: window, in: fixture.controller), true)
            window.close()
        }
        XCTAssertNil(released, "The old root must deallocate before a new root registers")
        let replacement = makeWindow()
        defer { replacement.close() }
        XCTAssertTrue(
            try windowRoots(in: fixture.controller).contains { root in
                try rootWindow(root) == nil
            },
            "The dead root must still be registered before replacement registration")
        fixture.controller.register(window: replacement)
        XCTAssertEqual(try suspension(of: replacement, in: fixture.controller), false)
    }

    func testExplicitShowClearsSuspensionWithinGrace() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        fixture.controller.prepareToHide(window: fixture.window)
        XCTAssertTrue(fixture.presentation.snapshot)
        fixture.controller.prepareToShow(window: fixture.window)
        XCTAssertFalse(fixture.presentation.snapshot)
        XCTAssertNil(fixture.cover)
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
private func makeWindow(
    size: NSSize = .init(width: 80, height: 80), styleMask: NSWindow.StyleMask = [.borderless]
) -> NSWindow {
    let window = NSWindow(
        contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
        styleMask: styleMask, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
private func windowRoots(in controller: MacAppProtection) throws -> [AnyObject] {
    try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "roots" }?.value as? [AnyObject])
}

@MainActor
private func rootWindow(_ root: AnyObject) throws -> NSWindow? {
    let field = try XCTUnwrap(Mirror(reflecting: root).children.first { $0.label == "window" })
    return field.value as? NSWindow
}

@MainActor
private func suspension(of window: NSWindow, in controller: MacAppProtection) throws -> Bool? {
    let roots = try windowRoots(in: controller)
    let root = try XCTUnwrap(
        try roots.first { candidate in
            try rootWindow(candidate) === window
        })
    return Mirror(reflecting: root).children.first { $0.label == "suspended" }?.value as? Bool
}

@MainActor
private final class Fixture {
    let window: NSWindow
    let gate: AccessGate
    let controller: MacAppProtection
    let presentation: ProtectedScopePresentation
    let owner = Owner()
    private let defaults: UserDefaults
    private let suite = "MacAppProtectionTests.\(UUID().uuidString)"

    var cover: NSPanel? { window.childWindows?.compactMap { $0 as? NSPanel }.first { $0.isVisible } }

    init(applicationIsActive: (@MainActor () -> Bool)? = { true }) throws {
        _ = NSApplication.shared
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        gate = AccessGate(authenticator: owner, defaults: defaults)
        if let applicationIsActive {
            controller = MacAppProtection(gate: gate, applicationIsActive: applicationIsActive)
        } else {
            controller = MacAppProtection(gate: gate)
        }
        presentation = ProtectedScopePresentation(gate: gate)
        window = makeWindow(size: .init(width: 320, height: 240), styleMask: [.titled, .closable])
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
    private(set) var calls = 0
    func availability() -> DeviceOwnerAuthAvailability { .available(.touchID) }
    func authenticate(reason: String) async -> DeviceOwnerAuthResult {
        calls += 1
        return .success
    }
    func cancel() {}
}

private struct SourceContent: View {
    let presentation: ProtectedScopePresentation
    var body: some View {
        // The production root modifier, which passes the host's window phase to the automatic prompt.
        Color(red: 1, green: 0, blue: 0).appProtection(presentation)
    }
}

@MainActor
private final class Activity {
    var isActive: Bool
    init(active: Bool) { isActive = active }
}
