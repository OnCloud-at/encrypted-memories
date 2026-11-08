import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import Testing
import UploadCore

@testable import EncryptedMemoriesMobile

/// Empty Recently Deleted on iPhone and iPad asks the duplicate merges first.
@MainActor @Suite struct MobileEmptyTrashTests {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var current: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    private final class StoreBox: @unchecked Sendable {
        private let lock = NSLock()
        private var held: PendingBackupManifestStore?
        var store: PendingBackupManifestStore? {
            get { lock.withLock { held } }
            set { lock.withLock { held = newValue } }
        }
    }

    private func makeLibrary(confirmsNoPendingMerges: Bool) async throws -> (MobileLibraryModel, Count) {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 2)
        let emptied = Count()
        var backend = MobileFixtureBackend(sections: fixture.sections, thumbnails: [:])
        backend.trashEmptier = { emptied.increment() }
        let model = MobileLibraryModel()
        fixture.install(
            into: model, backend: backend, sections: fixture.sections, thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        model.installIsolatedDuplicatesForTesting(
            MobileFixtureDuplicates(groups: [], confirmsNoPendingMerges: confirmsNoPendingMerges))
        return (model, emptied)
    }

    @Test func anOpenMergeThatCannotBeCheckedKeepsRecentlyDeleted() async throws {
        let (model, emptied) = try await makeLibrary(confirmsNoPendingMerges: false)

        await #expect(throws: RecentlyDeletedEmptying.PendingMergeCheck.self) {
            try await model.emptyTrash()
        }
        #expect(emptied.current == 0, "nothing is deleted while a merge waits for its check")
    }

    @Test func localOnlyEmptyingSkipsProtonAndTheMergeCheck() async throws {
        let (model, emptied) = try await makeLibrary(confirmsNoPendingMerges: false)

        let checks = Count()
        model.installIsolatedDuplicatesForTesting(countingDuplicates(checks))

        try await model.emptyTrash(includesProtonTrash: false)

        #expect(emptied.current == 0)
        #expect(checks.current == 0, "local-only emptying must not consult the merge check")
    }

    @Test(arguments: [false, true])
    func pendingRemovalPrecedesProtonAndFailureStopsIt(storeFails: Bool) async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 2)
        let model = MobileLibraryModel()
        let source = PendingSourceKey(kind: .photoLibraryAsset, identifier: "fixture-paused-photo")
        let emptied = Count()
        let storeBox = StoreBox()
        var backend = MobileFixtureBackend(sections: fixture.sections, thumbnails: [:])
        backend.trashEmptier = {
            #expect(
                storeBox.store?.sourceState(for: source)?.listedInTrash == false,
                "pending removal must finish before Proton")
            emptied.increment()
        }
        fixture.install(
            into: model, backend: backend, sections: fixture.sections, thumbnailFeed: fixture.feed,
            thumbnailCache: fixture.cache)
        model.installIsolatedDuplicatesForTesting(MobileFixtureDuplicates(groups: []))
        let pending = try MobilePendingOwnerFixture(
            model: model, canUpload: true, remote: PendingRemote(),
            prepare: { #expect($0.installPausedBackupFixtureForTesting()) })
        let store = pending.store
        storeBox.store = store
        do {
            let session = pending.session
            #expect(await eventually { session.pendingSnapshot.tiles.contains { $0.item.uid == source.localUID } })
            #expect(await session.delete([source.localUID]))
            #expect(await eventually { model.pendingTrash.localUIDs == [source.localUID] })
            #expect(store.sourceState(for: source)?.listedInTrash == true)

            if storeFails {
                store.close()
                await #expect(throws: CancellationError.self) { try await model.emptyTrash() }
                #expect(emptied.current == 0, "a failed pending removal must stop before Proton")
                #expect(model.pendingTrash.localUIDs == [source.localUID])
            } else {
                try await model.emptyTrash()
                #expect(emptied.current == 1)
                #expect(store.sourceState(for: source)?.listedInTrash == false)
                #expect(await eventually { model.pendingTrash.isEmpty })
            }
        } catch {
            await pending.close()
            throw error
        }
        await pending.close()
    }

    @Test func withoutABackendEmptyingDoesNothing() async throws {
        let model = MobileLibraryModel()
        let checks = Count()
        model.installIsolatedDuplicatesForTesting(countingDuplicates(checks))

        try await model.emptyTrash()

        #expect(checks.current == 0)
        #expect(model.pendingGrid == nil)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        await yieldUntil(timeout: .seconds(10), condition)
    }

    private func countingDuplicates(_ checks: Count) -> MobileFixtureDuplicates {
        MobileFixtureDuplicates(
            groups: [], confirmsNoPendingMerges: false, onConfirmNoPendingMerges: { checks.increment() })
    }

    private struct PendingRemote: PendingRemoteEffects {
        func trash(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
            Issue.record("a local pending photo must not call Proton trash")
            return .done
        }
        func restore(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
        func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
        func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
    }

    @Test func withoutAnOpenMergeRecentlyDeletedIsEmptied() async throws {
        let (model, emptied) = try await makeLibrary(confirmsNoPendingMerges: true)

        try await model.emptyTrash()

        #expect(emptied.current == 1)
    }
}
