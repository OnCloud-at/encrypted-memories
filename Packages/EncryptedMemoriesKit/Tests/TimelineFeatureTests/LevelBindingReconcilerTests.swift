import Foundation
import Testing
import TimelineCore

@testable import TimelineFeature

/// Binding-echo guard: a stale pre-commit binding must not re-drive a viewport-centre zoom.
/// The host owns the latch, while `LevelBindingReconciler` owns the decision table.
@Suite struct LevelBindingReconcilerTests {
    private func source(_ name: String) -> String {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return (try? String(contentsOf: url.appendingPathComponent("Sources/TimelineFeature/\(name)"), encoding: .utf8))
            ?? ""
    }

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

    @Test func updateNSViewRoutesThroughReconciler() {
        let view = source("MetalProductionGridView.swift")
        #expect(
            view.contains("host.reconcileLevelBinding(level)"),
            "updateNSView must reconcile the level binding through the echo-guarded path")
        #expect(
            !view.contains("if level != host.coordinator.level { host.animateToLevel(level) }"),
            "the legacy unguarded reconciliation must be gone (it re-issued a stale viewport-centre zoom)")
    }

    @Test func hostArmsEchoGuardAtEveryCommitSite() {
        let host = source("MetalGridScrollHost.swift")
        #expect(
            host.contains("LevelBindingReconciler.decide("),
            "reconcileLevelBinding must use the pure decision")
        // All three commit paths push the level through the arming helper (no bare onZoomCommit survives).
        let commitCalls = host.components(separatedBy: "commitLevelToBinding(previousLevel:").count - 1
        // 3 call sites (lattice / reflow / overview) + the helper's own parameter declaration = 4 textual matches.
        #expect(
            commitCalls >= 4,
            "lattice / reflow / overview commits must all arm the echo guard (found \(commitCalls - 1) sites)")
        // The binding may be pushed in exactly one place - the arming helper - so no commit site can bypass it.
        let bindingPushes = host.components(separatedBy: "onZoomCommit?(coordinator.level)").count - 1
        #expect(
            bindingPushes == 1,
            "the level binding must be pushed only via the echo-arming chokepoint (found \(bindingPushes))")
        // Armed only on a real level change (a no-op commit must not swallow the next external change).
        #expect(
            host.contains("if coordinator.level != previousLevel { pendingLevelEcho = previousLevel }"),
            "the echo guard must arm only when the commit actually changed the level")
    }
}
