import DesignSystemCore
import PhotosCore
import PrivacyFeature
import SwiftUI
import XCTest

@MainActor
final class ProtectedScopeModifierTests: ProtectedScopeTestCase {
    func testADisabledAreaKeepsItsContentVisible() throws {
        let gate = AccessGate(authenticator: PendingDeviceOwner(), defaults: defaults)
        XCTAssertEqual(
            try pixels(
                Color.red.protectedScope(
                    .app, gate: gate, unlockTitle: "Unlock", accessibilityLabel: "Locked", reason: "Unlock")),
            try pixels(Color.red))
    }

    func testALockedAreaCoversItsContent() throws {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let gate = AccessGate(authenticator: PendingDeviceOwner(), defaults: defaults)
        XCTAssertEqual(gate.state(of: .app), .locked)
        XCTAssertEqual(
            try pixels(
                Color.red.protectedScope(
                    .app, gate: gate, unlockTitle: "Unlock", accessibilityLabel: "Locked", reason: "Unlock")),
            try coverPixels(),
            "The protected-area modifier must replace the visible photo surface with the shared opaque cover")
    }

    func testSuccessfulAuthenticationRevealsTheMountedContent() async throws {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let owner = PendingDeviceOwner()
        let gate = AccessGate(authenticator: owner, defaults: defaults)
        let authentication = Task { await gate.unlock(.app, reason: "Unlock") }
        await fulfillment(of: [owner.requested], timeout: 5)
        owner.answer(.success)
        let result = await authentication.value
        XCTAssertEqual(result, .unlocked)
        XCTAssertEqual(
            try pixels(
                Color.red.protectedScope(
                    .app, gate: gate, unlockTitle: "Unlock", accessibilityLabel: "Locked", reason: "Unlock")),
            try pixels(Color.red))
    }

    func testCancelledAuthenticationKeepsTheContentCovered() async throws {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let owner = PendingDeviceOwner()
        let gate = AccessGate(authenticator: owner, defaults: defaults)
        let authentication = Task { await gate.unlock(.app, reason: "Unlock") }
        await fulfillment(of: [owner.requested], timeout: 5)
        owner.answer(.cancelled)
        let result = await authentication.value
        XCTAssertEqual(result, .locked)
        XCTAssertEqual(
            try pixels(
                Color.red.protectedScope(
                    .app, gate: gate, unlockTitle: "Unlock", accessibilityLabel: "Locked", reason: "Unlock")),
            try coverPixels())
    }

    private func coverPixels() throws -> Data {
        try pixels(
            ProtectedScopeCover(unlockTitle: "Unlock", accessibilityLabel: "Locked", isAuthenticating: false) {})
    }

    private func pixels(_ view: some View) throws -> Data {
        let renderer = ImageRenderer(
            content: view.frame(width: 320, height: 240).environment(\.colorScheme, .light))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        return try XCTUnwrap(image.dataProvider?.data) as Data
    }
}
