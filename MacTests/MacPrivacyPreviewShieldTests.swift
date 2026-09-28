import AppKit
import XCTest

final class MacPrivacyPreviewShieldTests: XCTestCase {
    @MainActor func testPreparationFinishesWhileCoveredAndToolbarReturnsWhenActive() {
        let window = makeWindow()
        let shield = MacPrivacyPreviewShield()
        shield.setToolbarContentVisible(false, on: window)
        update(shield, window: window, active: false)

        shield.setToolbarContentVisible(true, on: window)
        XCTAssertFalse(window.toolbar!.isVisible, "Finishing preparation must not expose the covered toolbar")
        XCTAssertEqual(window.contentView!.subviews.compactMap { $0 as? NSVisualEffectView }.count, 1)

        update(shield, window: window, active: true)
        XCTAssertTrue(window.toolbar!.isVisible, "Activation must restore the latest content state")
        XCTAssertTrue(window.contentView!.subviews.compactMap { $0 as? NSVisualEffectView }.isEmpty)
    }

    @MainActor func testNewPreparationWhileCoveredKeepsToolbarHiddenAfterActivation() {
        let window = makeWindow()
        let shield = MacPrivacyPreviewShield()
        shield.setToolbarContentVisible(true, on: window)
        update(shield, window: window, active: false)
        shield.setToolbarContentVisible(false, on: window)

        update(shield, window: window, active: true)
        XCTAssertFalse(window.toolbar!.isVisible, "The privacy shield must not override the loading cover")
        shield.setToolbarContentVisible(true, on: window)
        XCTAssertTrue(window.toolbar!.isVisible)
    }

    @MainActor func testReplacementToolbarUsesCurrentCoverageAndContentState() {
        let window = makeWindow()
        let shield = MacPrivacyPreviewShield()
        shield.setToolbarContentVisible(true, on: window)
        update(shield, window: window, active: false)
        window.toolbar = NSToolbar(identifier: "replacement")
        window.toolbar!.isVisible = true

        update(shield, window: window, active: false)
        XCTAssertFalse(window.toolbar!.isVisible)
        update(shield, window: window, active: true)
        XCTAssertTrue(window.toolbar!.isVisible)
    }

    @MainActor func testDisabledPreferenceLeavesInactiveWindowAndToolbarVisible() {
        let window = makeWindow()
        let shield = MacPrivacyPreviewShield()
        shield.setToolbarContentVisible(true, on: window)
        shield.update(window: window, enabled: false, isSceneActive: false, isWindowVisible: true)

        XCTAssertTrue(window.toolbar!.isVisible)
        XCTAssertTrue(window.contentView!.subviews.compactMap { $0 as? NSVisualEffectView }.isEmpty)
    }

    @MainActor private func update(_ shield: MacPrivacyPreviewShield, window: NSWindow, active: Bool) {
        shield.update(window: window, enabled: true, isSceneActive: active, isWindowVisible: true)
    }

    @MainActor private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "privacy-test")
        window.toolbar!.isVisible = true
        return window
    }
}
