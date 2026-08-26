import Foundation

// MARK: - Level-binding reconciliation (host-led commit vs SwiftUI @Binding echo)
//
// AppKit commits `hostLevel` before SwiftUI delivers the binding. Ignore the armed stale value,
// clear the latch when the binding catches up, and honor any other external value.
package enum LevelBindingReconciler {
    package enum Action: Equatable {
        case ignore  // already in sync, or a stale post-commit echo - do nothing
        case clearLatch  // the binding caught up to the host level - clear the echo guard, do nothing else
        case reDrive(Int)  // a genuine external level change - drive `animateToLevel(_)` (and clear the guard)
    }

    /// Decide what an `updateNSView` pass should do with a delivered `level`-binding value.
    /// - Parameters:
    ///   - binding:   the SwiftUI `@Binding level` value delivered to this pass.
    ///   - hostLevel: the host's authoritative `coordinator.level`.
    ///   - staleEcho: the pre-commit level whose lingering binding echo must be ignored (nil = none armed).
    package static func decide(binding: Int, hostLevel: Int, staleEcho: Int?) -> Action {
        if binding == hostLevel { return .clearLatch }  // binding consistent with the host
        if let staleEcho, binding == staleEcho { return .ignore }  // Keep the stale echo guard armed.
        return .reDrive(binding)  // Apply a genuine external change.
    }
}
