import Foundation

@testable import PhotosCore

/// An original provider for export and staging tests: fixed payloads and metadata per photo, and photos that fail.
final class FakeOriginalProvider: OriginalFileProvider, PhotoMetadataProvider, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private let payloads: [PhotoUID: Data]
    private let metadataByUID: [PhotoUID: PhotoMetadata]
    private let failing: Set<PhotoUID>
    private var writes = 0

    init(
        payloads: [PhotoUID: Data],
        metadata: [PhotoUID: PhotoMetadata] = [:],
        failing: Set<PhotoUID> = []
    ) {
        self.payloads = payloads
        self.metadataByUID = metadata
        self.failing = failing
    }

    var writeCount: Int { lock.withLock { writes } }

    func writeOriginal(
        for uid: PhotoUID,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        lock.withLock { writes += 1 }
        guard !failing.contains(uid), let payload = payloads[uid] else { throw Failure() }
        try payload.write(to: destination)
        onProgress(1)
    }

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        guard let metadata = metadataByUID[uid] else { throw Failure() }
        return metadata
    }
}
