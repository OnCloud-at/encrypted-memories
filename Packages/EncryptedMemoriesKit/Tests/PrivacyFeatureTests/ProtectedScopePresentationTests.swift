import PhotosCore
import PrivacyFeature
import SwiftUI
import XCTest

@MainActor
final class ProtectedScopePresentationTests: ProtectedScopeTestCase {
    func testDisabledProtectionDoesNotCoverAnInactiveWindow() {
        let presentation = makePresentation(enabled: false)
        XCTAssertFalse(presentation.update(isActive: false))
        XCTAssertFalse(presentation.snapshot)
        XCTAssertEqual(presentation.phase, .inactive)
    }

    func testEnabledProtectionCoversAnInactiveUnlockedWindow() async {
        let presentation = makePresentation(enabled: true)
        await unlock(presentation.gate)
        XCTAssertTrue(presentation.update(isActive: false))
        XCTAssertTrue(presentation.snapshot)
        XCTAssertEqual(presentation.phase, .inactive)
        XCTAssertTrue(presentation.gate.admits(.app))
    }

    func testActiveLockedAndUnlockedWindowsUseAdmission() async {
        let presentation = makePresentation(enabled: true)
        XCTAssertTrue(presentation.update(isActive: true))
        XCTAssertFalse(presentation.snapshot)
        XCTAssertEqual(presentation.phase, .active)
        await unlock(presentation.gate)
        XCTAssertFalse(presentation.update(isActive: true))
    }

    func testObservationRearmsAndStopsAfterInvalidation() async {
        let presentation = makePresentation(enabled: true)
        var changes = 0
        let observation = ProtectedScopeObservation(gate: presentation.gate) { changes += 1 }
        await unlock(presentation.gate)
        let first = await awaitChanges { changes > 0 }
        XCTAssertTrue(first)
        let afterUnlock = changes
        presentation.gate.systemDidLock()
        let second = await awaitChanges { changes > afterUnlock }
        XCTAssertTrue(second)
        observation.invalidate()
        let afterInvalidation = changes
        await unlock(presentation.gate)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(changes, afterInvalidation)
    }

    private func makePresentation(enabled: Bool) -> ProtectedScopePresentation {
        defaults.set(enabled, forKey: AppSettingsKey.appLockEnabled)
        return ProtectedScopePresentation(gate: AccessGate(authenticator: PresentationOwner(), defaults: defaults))
    }

    private func unlock(_ gate: AccessGate) async { _ = await gate.unlock(.app, reason: "Unlock") }

    private func awaitChanges(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        return predicate()
    }
}

@MainActor
private final class PresentationOwner: DeviceOwnerAuthenticating {
    func availability() -> DeviceOwnerAuthAvailability { .available(.touchID) }
    func authenticate(reason: String) async -> DeviceOwnerAuthResult { .success }
    func cancel() {}
}
