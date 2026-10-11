import Foundation
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

    @Test func withoutAnOpenMergeRecentlyDeletedIsEmptied() async throws {
        let (model, emptied) = try await makeLibrary(confirmsNoPendingMerges: true)

        try await model.emptyTrash()

        #expect(emptied.current == 1)
    }
}
