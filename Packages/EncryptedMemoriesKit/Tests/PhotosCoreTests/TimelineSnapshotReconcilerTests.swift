import Foundation
import Testing

@testable import PhotosCore

@MainActor
@Suite("Collection snapshot reconciliation")
struct TimelineSnapshotReconcilerTests {
    @Test(arguments: [false, true])
    func concurrentRemovalsRebaseInEitherCompletionOrder(reverse: Bool) async {
        let gate = SnapshotTransformGate(blockedCalls: 2)
        let owner = TimelineSnapshotReconciler(snapshot: snapshot(["a", "b", "c"])) {
            await gate.transform($0, removing: $1)
        }
        let epoch = owner.epoch
        let first = Task { await owner.remove([uid("a")], within: epoch) }
        await gate.waitForCalls(1)
        let second = Task { await owner.remove([uid("b")], within: epoch) }
        await gate.waitForCalls(2)
        await gate.release(reverse ? 1 : 0)
        if reverse { _ = await second.value } else { _ = await first.value }
        await gate.release(reverse ? 0 : 1)
        #expect(await first.value)
        #expect(await second.value)
        #expect(owner.snapshot.items.map(\.uid.nodeID) == ["c"])
    }

    @Test func newerRetryRejectsBothSuccessAndFailureFromOlderLoad() {
        let owner = TimelineSnapshotReconciler(snapshot: snapshot(["initial"]))
        let olderLoad = owner.beginLoad()
        let retry = owner.beginLoad()
        #expect(!owner.isCurrent(olderLoad))
        #expect(!owner.publishLoaded(snapshot(["stale"]), token: olderLoad))
        #expect(owner.isCurrent(retry))
        #expect(owner.publishLoaded(snapshot(["current"]), token: retry))
        #expect(!owner.isCurrent(olderLoad))
        #expect(!owner.publishLoaded(snapshot(["stale"]), token: olderLoad))
        #expect(owner.snapshot.items.map(\.uid.nodeID) == ["current"])
    }

    @Test func loadStartedBeforeRemovalCannotRestoreRemovedItem() async {
        let owner = TimelineSnapshotReconciler(snapshot: snapshot(["a", "b"]))
        let staleLoad = owner.beginLoad()
        #expect(await owner.remove([uid("a")], within: owner.epoch))
        #expect(!owner.publishLoaded(snapshot(["a", "b"]), token: staleLoad))
        #expect(owner.snapshot.items.map(\.uid.nodeID) == ["b"])
        let laterLoad = owner.beginLoad()
        #expect(owner.publishLoaded(snapshot(["a", "b", "c"]), token: laterLoad))
        #expect(owner.snapshot.items.map(\.uid.nodeID) == ["a", "b", "c"])
    }

    @Test func removalRebasesOverLoadPublishedWhileTransformWasSuspended() async {
        let gate = SnapshotTransformGate(blockedCalls: 1)
        let owner = TimelineSnapshotReconciler(snapshot: snapshot(["a", "b"])) {
            await gate.transform($0, removing: $1)
        }
        let epoch = owner.epoch
        let removal = Task { await owner.remove([uid("a")], within: epoch) }
        await gate.waitForCalls(1)
        let load = owner.beginLoad()
        #expect(owner.publishLoaded(snapshot(["a", "b", "c"]), token: load))
        let pendingLoad = owner.beginLoad()
        await gate.release(0)
        #expect(await removal.value)
        #expect(owner.snapshot.items.map(\.uid.nodeID) == ["b", "c"])
        #expect(!owner.publishLoaded(snapshot(["a", "b"]), token: pendingLoad))
    }

    @Test func resetFencesBothSuspendedRemovalsAndOldLoadTokens() async {
        let gate = SnapshotTransformGate(blockedCalls: 1)
        let owner = TimelineSnapshotReconciler(snapshot: snapshot(["a", "b"])) {
            await gate.transform($0, removing: $1)
        }
        let epoch = owner.epoch
        let load = owner.beginLoad()
        let removal = Task { await owner.remove([uid("a")], within: epoch) }
        await gate.waitForCalls(1)
        owner.reset(to: snapshot(["a", "new-account"]))
        await gate.release(0)
        #expect(!(await removal.value))
        #expect(!owner.publishLoaded(snapshot(["old-account"]), token: load))
        #expect(owner.snapshot.items.map(\.uid.nodeID) == ["a", "new-account"])
    }

    @Test func confirmedRemovalFinishesLocalCommitAfterCallerCancellation() async {
        let gate = SnapshotTransformGate(blockedCalls: 1)
        let owner = TimelineSnapshotReconciler(snapshot: snapshot(["a", "b"])) {
            await gate.transform($0, removing: $1)
        }
        let epoch = owner.epoch
        var commits = 0
        let removal = Task {
            await owner.remove([uid("a")], within: epoch) { update in
                commits += 1
                update()
            }
        }
        await gate.waitForCalls(1)
        removal.cancel()
        await gate.release(0)
        #expect(await removal.value)
        #expect(commits == 1)
        #expect(owner.snapshot.items.map(\.uid.nodeID) == ["b"])
    }

    private func uid(_ value: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: value) }
    private func snapshot(_ values: [String]) -> TimelineSnapshot {
        TimelineSnapshot(
            orderedItems: values.enumerated().map { offset, value in
                PhotoItem(
                    uid: uid(value), captureTime: Date(timeIntervalSince1970: Double(offset)), mediaType: "image/jpeg")
            })
    }
}

private actor SnapshotTransformGate {
    private let blockedCalls: Int
    private var calls = 0
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]

    init(blockedCalls: Int) { self.blockedCalls = blockedCalls }

    func transform(_ snapshot: TimelineSnapshot, removing uids: Set<PhotoUID>) async -> TimelineSnapshot {
        let call = calls
        calls += 1
        if call < blockedCalls {
            await withCheckedContinuation { pending[call] = $0 }
        }
        return snapshot.removingItems(withUIDs: uids)
    }

    func waitForCalls(_ count: Int) async {
        while calls < count { await Task.yield() }
    }

    func release(_ call: Int) {
        pending.removeValue(forKey: call)?.resume()
    }
}
