import Foundation
import MediaFeedCore
import PhotosCore
import Testing

@testable import TimelineCore

@Suite @MainActor struct LibraryThumbnailUpdateCoordinatorTests {
    @Test func inventoryDeltaReturnsOnlyAddedUIDsInCurrentOrder() {
        let previous = [uid("a"), uid("b"), uid("removed")]
        let current = [uid("b"), uid("c"), uid("a"), uid("d"), uid("c")]

        #expect(LibraryInventoryDelta.addedUIDs(previous: previous, current: current) == [uid("c"), uid("d")])
    }

    @Test func noAddedAssetsNeverStartsPresentationOrResolver() async {
        let calls = CallCounter()
        let coordinator = LibraryThumbnailUpdateCoordinator(policy: fastPolicy)

        coordinator.reconcile(currentUIDs: [uid("a")], addedUIDs: []) { _, _ in
            await calls.increment()
            return LibraryThumbnailResolutionSnapshot()
        }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(!coordinator.state.isActive)
        let callCount = await calls.value
        #expect(callCount == 0)
    }

    @Test func batchStaysVisibleWithoutDeadlineUntilEveryAddedThumbnailSettles() async {
        let availability = Availability()
        let coordinator = LibraryThumbnailUpdateCoordinator(policy: fastPolicy)
        let added = [uid("new-1"), uid("new-2")]

        coordinator.reconcile(currentUIDs: added, addedUIDs: added) { uids, _ in
            await availability.resolution(for: uids)
        }
        await eventually { coordinator.state.pendingCount == 2 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(coordinator.state.pendingCount == 2)

        await availability.makeAvailable(uid("new-1"))
        await eventually { coordinator.state.pendingCount == 1 }
        await availability.makeAvailable(uid("new-2"))
        await eventually { !coordinator.state.isActive }
    }

    @Test func laterRefreshMergesNewIDsAndRemovesDeletedPendingIDs() async {
        let availability = Availability()
        let coordinator = LibraryThumbnailUpdateCoordinator(policy: fastPolicy)
        let first = uid("first")
        let deleted = uid("deleted")
        let later = uid("later")

        coordinator.reconcile(currentUIDs: [first, deleted], addedUIDs: [first, deleted]) { uids, _ in
            await availability.resolution(for: uids)
        }
        await eventually { coordinator.state.pendingCount == 2 }
        coordinator.reconcile(currentUIDs: [first, later], addedUIDs: [later]) { uids, _ in
            await availability.resolution(for: uids)
        }
        await eventually { coordinator.state.pendingCount == 2 }

        await availability.makeAvailable(first)
        await availability.makeTerminal(later)
        await eventually { !coordinator.state.isActive }
    }

    @Test func cancelHidesPresentationAndJoinsRetiringWorker() async {
        let coordinator = LibraryThumbnailUpdateCoordinator(policy: fastPolicy)
        let added = [uid("new")]
        coordinator.reconcile(currentUIDs: added, addedUIDs: added) { _, _ in
            try? await Task.sleep(for: .seconds(5))
            return LibraryThumbnailResolutionSnapshot()
        }
        await eventually { coordinator.state.isActive }

        let retiring = coordinator.cancel()
        await retiring?.value

        #expect(!coordinator.state.isActive)
    }

    @Test func stateHandlerPublishesPlatformPresentationChanges() async {
        var states: [LibraryThumbnailUpdateState] = []
        let coordinator = LibraryThumbnailUpdateCoordinator(policy: fastPolicy)
        let added = [uid("new")]

        coordinator.reconcile(
            currentUIDs: added,
            addedUIDs: added,
            onStateChange: { states.append($0) },
            resolver: { uids, _ in
                LibraryThumbnailResolutionSnapshot(availableUIDs: uids)
            }
        )
        await eventually { !coordinator.state.isActive }

        #expect(states.first?.pendingCount == 1)
        #expect(states.last == .idle)
    }

    private var fastPolicy: LibraryThumbnailUpdatePolicy {
        LibraryThumbnailUpdatePolicy(
            pollInterval: .milliseconds(5),
            maximumStatusBatch: 2,
            pollsBetweenRetries: 2
        )
    }

    private func uid(_ value: String) -> PhotoUID {
        PhotoUID(volumeID: "v", nodeID: value)
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Condition did not become true")
    }
}

private actor Availability {
    private var available = Set<PhotoUID>()
    private var terminal = Set<PhotoUID>()

    func makeAvailable(_ uid: PhotoUID) { available.insert(uid) }
    func makeTerminal(_ uid: PhotoUID) { terminal.insert(uid) }

    func resolution(for uids: [PhotoUID]) -> LibraryThumbnailResolutionSnapshot {
        LibraryThumbnailResolutionSnapshot(
            availableUIDs: uids.filter { available.contains($0) },
            terminalUIDs: uids.filter { terminal.contains($0) }
        )
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
