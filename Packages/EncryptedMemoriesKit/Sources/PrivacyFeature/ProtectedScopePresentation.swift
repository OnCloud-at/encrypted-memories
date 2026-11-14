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
}

extension EnvironmentValues {
    @Entry public var protectedContentIsCovered = false
}

@MainActor
extension View {
    /// Conceals mounted content while preserving its tasks and state.
    public func protectedContent(isCovered: Bool) -> some View {
        opacity(isCovered ? 0 : 1)
            .disabled(isCovered)
            .allowsHitTesting(!isCovered)
            .accessibilityHidden(isCovered)
            .transformEnvironment(\.protectedContentIsCovered) { $0 = $0 || isCovered }
    }
}
