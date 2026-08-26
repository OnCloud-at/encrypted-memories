import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

@Suite("Video byte-range cache generations")
struct VideoByteRangeCacheTests {
    private func makeCache(budgetBytes: Int = 1024 * 1024) -> (cache: VideoByteRangeCache, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EncryptedMemories-VideoByteRangeCacheTests-\(UUID().uuidString)", isDirectory: true)
        return (VideoByteRangeCache(budgetBytes: budgetBytes, rootDirectory: root), root)
    }

    private func uid(_ id: String) -> PhotoUID {
        PhotoUID(volumeID: "video-cache-test-volume", nodeID: id)
    }

    @Test func newerRequestWinsWhenOlderRequestCompletesLast() {
        let fixture = makeCache()
        let cache = fixture.cache
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let photo = uid("new-first-old-last")

        let oldOwner = cache.captureOwnerGeneration()
        let oldRequest = cache.lookup(uid: photo, block: 1)
        #expect(oldRequest.encrypted == nil)

        cache.clearAll()
        let newOwner = cache.captureOwnerGeneration()
        let newRequest = cache.lookup(uid: photo, block: 1)
        #expect(newRequest.encrypted == nil)
        #expect(
            cache.store(
                uid: photo,
                block: 1,
                encrypted: Data("new".utf8),
                ticket: newRequest.ticket,
                ownerGeneration: newOwner
            ))
        #expect(
            cache.store(
                uid: photo,
                block: 1,
                encrypted: Data("old".utf8),
                ticket: oldRequest.ticket,
                ownerGeneration: oldOwner
            ) == false)

        #expect(cache.lookup(uid: photo, block: 1).encrypted == Data("new".utf8))
    }

    @Test func abandonedMissDoesNotReserveOrConsumeTheNextRequest() {
        let fixture = makeCache()
        let cache = fixture.cache
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let photo = uid("abandoned-miss")

        let owner = cache.captureOwnerGeneration()
        // This request models a failed or cancelled network operation. It captures no cache-side
        // reservation, and therefore has no state that the next successful request can consume.
        _ = cache.lookup(uid: photo, block: 2)
        let successfulRequest = cache.lookup(uid: photo, block: 2)

        #expect(
            cache.store(
                uid: photo,
                block: 2,
                encrypted: Data("survivor".utf8),
                ticket: successfulRequest.ticket,
                ownerGeneration: owner
            ))
        #expect(cache.lookup(uid: photo, block: 2).encrypted == Data("survivor".utf8))
    }

    @Test func staleOwnerCannotUsePostClearLookup() {
        let fixture = makeCache()
        let cache = fixture.cache
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let photo = uid("stale-owner-post-clear")

        let staleOwner = cache.captureOwnerGeneration()
        cache.clearAll()
        let freshOwner = cache.captureOwnerGeneration()
        let freshLookup = cache.lookup(uid: photo, block: 3)

        #expect(
            cache.store(
                uid: photo,
                block: 3,
                encrypted: Data("stale".utf8),
                ticket: freshLookup.ticket,
                ownerGeneration: staleOwner
            ) == false)
        #expect(cache.lookup(uid: photo, block: 3).encrypted == nil)
        #expect(
            cache.store(
                uid: photo,
                block: 3,
                encrypted: Data("fresh".utf8),
                ticket: freshLookup.ticket,
                ownerGeneration: freshOwner
            ))
        #expect(cache.lookup(uid: photo, block: 3).encrypted == Data("fresh".utf8))
    }

    @Test func concurrentStoresDoNotInvertGenerationAndCacheLocks() {
        let fixture = makeCache(budgetBytes: 1)
        let cache = fixture.cache
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let queue = DispatchQueue(
            label: "EncryptedMemories.VideoByteRangeCacheTests.lock-order",
            attributes: .concurrent
        )
        let group = DispatchGroup()

        for round in 0..<8 {
            for block in 0..<4 {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    let owner = cache.captureOwnerGeneration()
                    let lookup = cache.lookup(uid: uid("lock-order-\(round)-\(block)"), block: block)
                    _ = cache.store(
                        uid: uid("lock-order-\(round)-\(block)"),
                        block: block,
                        encrypted: Data("payload-\(round)-\(block)".utf8),
                        ticket: lookup.ticket,
                        ownerGeneration: owner
                    )
                }
            }
        }

        #expect(
            // The deadline fails if concurrent budget enforcement deadlocks.
            group.wait(timeout: .now() + 10) == .success,
            "concurrent cache stores must not deadlock during budget enforcement"
        )
    }

    @Test func asyncRangeCacheRoundTripUsesTheSameGenerationContract() async {
        let fixture = makeCache()
        let cache = fixture.cache
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let photo = uid("async-round-trip")
        let owner = cache.captureOwnerGeneration()
        let lookup = await cache.lookupAsync(uid: photo, block: 1)

        #expect(
            await cache.storeAsync(
                uid: photo,
                block: 1,
                encrypted: Data("async-payload".utf8),
                ticket: lookup.ticket,
                ownerGeneration: owner
            ))
        let result = await cache.lookupAsync(uid: photo, block: 1)
        #expect(result.encrypted == Data("async-payload".utf8))
    }
}
