import Observation
import PhotosCore
import SwiftUI

/// Adapts native settings controls to the shared gate. Results `.cancelled` and `.failed` preserve the saved choice;
/// `.noDeviceLock` lets the gate turn protection off. The duration picker reads and writes the gate directly,
/// without another preference store.
@MainActor
@Observable
public final class ProtectedScopeSettings {
    private let gate: AccessGate
    private let scope: ProtectedScope
    private let reason: String
    public private(set) var isChanging = false

    public init(gate: AccessGate, scope: ProtectedScope, reason: String) {
        self.gate = gate
        self.scope = scope
        self.reason = reason
    }

    public var canChange: Bool {
        !isChanging && !gate.isAuthenticating && gate.availability != .noDeviceLock
    }

    public var enabled: Binding<Bool> {
        Binding(
            get: { self.gate.isEnabled(self.scope) },
            set: { enabled in
                guard self.canChange, enabled != self.gate.isEnabled(self.scope) else { return }
                // Disable the controls before scheduling the task, so taps in the same turn cannot queue changes.
                self.isChanging = true
                Task {
                    _ = await self.gate.setEnabled(enabled, for: self.scope, reason: self.reason)
                    self.isChanging = false
                }
            })
    }

    public var gracePeriod: Binding<Duration> {
        Binding(
            get: { self.gate.gracePeriod(of: self.scope) },
            set: { duration in
                guard self.canChange else { return }
                self.gate.setGracePeriod(duration, for: self.scope)
            })
    }
}
