import DesignSystemCore
import PhotosCore
import SwiftUI

@MainActor
extension View {
    /// Keeps the content mounted while the shared gate covers it. The caller supplies the area-specific copy.
    public func protectedScope(
        _ scope: ProtectedScope, gate: AccessGate, unlockTitle: String, accessibilityLabel: String,
        reason: String, contentBounds: CGRect? = nil
    ) -> some View {
        modifier(
            ProtectedScopeModifier(
                scope: scope, gate: gate, unlockTitle: unlockTitle, accessibilityLabel: accessibilityLabel,
                reason: reason, contentBounds: contentBounds))
    }
}

@MainActor
private struct ProtectedScopeModifier: ViewModifier {
    let scope: ProtectedScope
    let gate: AccessGate
    let unlockTitle: String
    let accessibilityLabel: String
    let reason: String
    let contentBounds: CGRect?
    @Environment(\.scenePhase) private var scenePhase
    @State private var presence: ProtectedScopePresence?

    private var identity: Identity { Identity(scope: scope, gate: ObjectIdentifier(gate)) }
    private var isCovered: Bool { gate.state(of: scope) != .unlocked }

    func body(content: Content) -> some View {
        content
            .disabled(isCovered)
            .allowsHitTesting(!isCovered)
            .accessibilityHidden(isCovered)
            .overlay {
                if isCovered {
                    ProtectedScopeCover(
                        unlockTitle: unlockTitle, accessibilityLabel: accessibilityLabel,
                        isAuthenticating: gate.isAuthenticating, contentBounds: contentBounds
                    ) {
                        Task { await gate.unlock(scope, reason: reason) }
                    }
                    .task(
                        id: Activity(
                            identity: identity, scenePhase: scenePhase,
                            parentIsOpen: scope.parent.map(gate.admits) ?? true)
                    ) {
                        guard scenePhase == .active, !Task.isCancelled else { return }
                        await gate.unlockAutomatically(scope, reason: reason)
                    }
                }
            }
            .onAppear {
                if presence == nil { presence = gate.enter(scope) }
            }
            .onChange(of: identity) { _, _ in
                guard presence != nil else { return }
                presence?.release()
                presence = gate.enter(scope)
            }
            .onDisappear {
                presence?.release()
                presence = nil
            }
    }

    private struct Identity: Equatable {
        let scope: ProtectedScope
        let gate: ObjectIdentifier
    }

    private struct Activity: Equatable {
        let identity: Identity
        let scenePhase: ScenePhase
        let parentIsOpen: Bool
    }
}
