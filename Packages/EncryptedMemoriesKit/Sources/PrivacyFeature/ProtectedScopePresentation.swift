import DesignSystemCore
import Observation
import PhotosCore
import SwiftUI

/// Native hosts update the phase and snapshot coverage before their windows change visibility.
@MainActor @Observable
public final class ProtectedScopePresentation {
    public let gate: AccessGate
    public var phase: ScenePhase = .inactive
    public var snapshot = false

    public init(gate: AccessGate) { self.gate = gate }

    /// Native hosts supply activity before exposing or snapshotting their windows.
    @discardableResult
    public func update(isActive: Bool) -> Bool {
        let coverage = ProtectedScopeCoverage(gate: gate, isActive: isActive)
        snapshot = coverage.snapshot
        phase = coverage.phase
        return coverage.isCovered
    }
}

/// The same coverage rule serves native window adapters and mounted SwiftUI roots.
@MainActor
public struct ProtectedScopeCoverage {
    public let snapshot: Bool
    public let phase: ScenePhase
    public let isCovered: Bool

    public init(gate: AccessGate, isActive: Bool) {
        snapshot = !isActive && gate.isEnabled(.app)
        phase = isActive ? .active : .inactive
        isCovered = snapshot || !gate.admits(.app)
    }
}

/// One subscription shape for native adapters that must refresh outside SwiftUI.
@MainActor
public final class ProtectedScopeObservation {
    private let gate: AccessGate
    private let onChange: @MainActor () -> Void
    private var observing = true

    public init(gate: AccessGate, onChange: @escaping @MainActor () -> Void) {
        self.gate = gate
        self.onChange = onChange
        observe()
    }

    public func invalidate() { observing = false }

    private func observe() {
        guard observing else { return }
        withObservationTracking {
            _ = gate.state(of: .app)
            _ = gate.isEnabled(.app)
            _ = gate.availability
            _ = gate.isAuthenticating
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observing else { return }
                self.observe()
                self.onChange()
            }
        }
    }
}

@MainActor
extension View {
    /// Uses the approved app copy for every native cover and protected root.
    public func appProtection(_ presentation: ProtectedScopePresentation, contentBounds: CGRect? = nil) -> some View {
        protectedScope(
            .app, gate: presentation.gate,
            unlockTitle: AppLockCopy.unlockTitle(for: presentation.gate.availability),
            accessibilityLabel: AppLockCopy.lockedLabel, reason: AppLockCopy.unlockReason,
            contentBounds: contentBounds, snapshot: presentation.snapshot)
    }

    /// Conceals mounted content while preserving its tasks and state.
    public func protectedContent(isCovered: Bool) -> some View {
        opacity(isCovered ? 0 : 1)
            .disabled(isCovered)
            .allowsHitTesting(!isCovered)
            .accessibilityHidden(isCovered)
            .transformEnvironment(\.protectedContentIsCovered) { $0 = $0 || isCovered }
    }
}
