import DesignSystemCore
import PhotosCore
import SwiftUI

@MainActor
extension View {
    /// Keeps the content mounted while the shared gate covers it. The caller supplies the area-specific copy.
    public func protectedScope(
        _ scope: ProtectedScope, gate: AccessGate, unlockTitle: String, accessibilityLabel: String,
        reason: String, contentBounds: CGRect? = nil, snapshot: Bool = false
    ) -> some View {
        modifier(
            ProtectedScopeModifier(
                scope: scope, gate: gate, unlockTitle: unlockTitle, accessibilityLabel: accessibilityLabel,
                reason: reason, contentBounds: contentBounds, snapshot: snapshot))
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
    let snapshot: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var presence: ProtectedScopePresence?

    private var identity: Identity { Identity(scope: scope, gate: ObjectIdentifier(gate)) }
    private var isCovered: Bool { snapshot || gate.state(of: scope) != .unlocked }

    func body(content: Content) -> some View {
        content
            .protectedContent(isCovered: isCovered)
            .overlay {
                if isCovered {
                    ProtectedScopeCover(
                        unlockTitle: unlockTitle, accessibilityLabel: accessibilityLabel,
                        isAuthenticating: snapshot || gate.isAuthenticating, contentBounds: contentBounds
                    ) {
                        Task { await gate.unlock(scope, reason: reason) }
                    }
                    .transition(.identity)
                    .task(
                        id: Activity(
                            identity: identity, scenePhase: scenePhase,
                            parentIsOpen: scope.parent.map(gate.admits) ?? true, snapshot: snapshot)
                    ) {
                        guard !snapshot, scenePhase == .active, !Task.isCancelled else { return }
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
            .animation(nil, value: isCovered)
    }

    private struct Identity: Equatable {
        let scope: ProtectedScope
        let gate: ObjectIdentifier
    }

    private struct Activity: Equatable {
        let identity: Identity
        let scenePhase: ScenePhase
        let parentIsOpen: Bool
        let snapshot: Bool
    }
}
