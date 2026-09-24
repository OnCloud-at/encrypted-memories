import Foundation
import Testing
import TimelineCore

@testable import TimelineFeature

/// Binding-echo guard: a stale pre-commit binding must not re-drive a viewport-centre zoom.
/// The host owns the latch, while `LevelBindingReconciler` owns the decision table.
@Suite struct LevelBindingReconcilerTests {
    @Test func stalePostCommitEchoIsIgnored() {
        // Pinch committed S=3 to N=1; the host armed the echo guard with the pre-commit level (3). A coincident
        // updateNSView pass delivers the stale binding S=3 while the host is already at N=1.
        let action = LevelBindingReconciler.decide(binding: 3, hostLevel: 1, staleEcho: 3)
        #expect(action == .ignore, "a stale pre-commit echo must be ignored, never re-drive animateToLevel")
    }

    @Test func bindingCatchUpClearsLatch() {
        let action = LevelBindingReconciler.decide(binding: 1, hostLevel: 1, staleEcho: 3)
        #expect(action == .clearLatch, "when the binding reaches the committed level the latch clears (no re-drive)")
    }

    @Test func genuineExternalChangeWhileLatchedIsHonoured() {
        // Host at N=1 (just committed from 3); user presses − to go to level 2. 2 ≠ host(1) and 2 ≠ stale(3).
        let action = LevelBindingReconciler.decide(binding: 2, hostLevel: 1, staleEcho: 3)
        #expect(action == .reDrive(2), "a genuine external change that isn't the stale value must re-drive")
    }

    @Test func noLatchBehavesLikeLegacyGuard() {
        #expect(
            LevelBindingReconciler.decide(binding: 4, hostLevel: 2, staleEcho: nil) == .reDrive(4),
            "external change with no latch must re-drive (legacy `if level != coordinator.level` behaviour)")
        #expect(
            LevelBindingReconciler.decide(binding: 2, hostLevel: 2, staleEcho: nil) == .clearLatch,
            "in-sync with no latch is a no-op")
    }

    @Test func latchOnlySuppressesTheStaleValueAndRecovers() {
        // Multiple stale passes (all S) are each ignored while the latch is armed…
        #expect(LevelBindingReconciler.decide(binding: 3, hostLevel: 1, staleEcho: 3) == .ignore)
        #expect(LevelBindingReconciler.decide(binding: 3, hostLevel: 1, staleEcho: 3) == .ignore)
        // …but the very next NON-stale binding value re-drives (clearing the latch in the host), so a legitimate
        // change can never be swallowed for more than the one stale value - the latch can't get permanently stuck.
        #expect(LevelBindingReconciler.decide(binding: 0, hostLevel: 1, staleEcho: 3) == .reDrive(0))
    }
}
