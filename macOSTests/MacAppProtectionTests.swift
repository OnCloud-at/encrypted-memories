import AppKit
import PhotosCore
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

    func testSuccessfulAuthenticationRemovesTheChildCover() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        let hidden = await fixture.waitForCover(visible: false)
        XCTAssertTrue(hidden)
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
        let hidden = await fixture.waitForCover(visible: false)
        XCTAssertTrue(hidden)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertFalse(fixture.gate.admits(.app))
        XCTAssertNotNil(fixture.cover)
    }

    func testClosingTheLastWindowStartsTheBackgroundGracePeriod() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = await fixture.gate.unlock(.app, reason: "Unlock")
        fixture.window.close()
        fixture.gate.appWillEnterForeground(at: .now + .seconds(120))
        XCTAssertFalse(fixture.gate.admits(.app))
    }
}

@MainActor
private final class Fixture {
    let window: NSWindow
    let gate: AccessGate
    let controller: MacAppProtection
    private let defaults: UserDefaults
    private let suite = "MacAppProtectionTests.\(UUID().uuidString)"

    var cover: NSPanel? { window.childWindows?.compactMap { $0 as? NSPanel }.first { $0.isVisible } }

    init() throws {
        _ = NSApplication.shared
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        gate = AccessGate(authenticator: Owner(), defaults: defaults)
        controller = MacAppProtection(gate: gate)
        window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 320, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Color.red)
        window.orderFront(nil)
        controller.register(window: window)
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
