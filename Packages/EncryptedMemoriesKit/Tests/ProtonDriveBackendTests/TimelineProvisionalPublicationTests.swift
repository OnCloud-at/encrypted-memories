import Foundation
import PhotosCore
import ProtonAuth
import SQLiteTestSupport
import Testing

@testable import ProtonDriveBackend
@testable import ProtonDriveSDK

extension DriveSessionStubSuite {
    @Suite struct TimelineProvisionalPublicationTests {
        @Test func theFirstPagePublishesWithoutCompletingOrReplacingTheCache() async throws {
            try await withFixture { bridge, store, old, oldToken in
                let observations = ProvisionalObservations()
                let repository: any PhotosRepository = bridge
                let load = Task {
                    do {
                        let result = try await repository.loadTimelineSnapshot { provisional in
                            observations.received(provisional)
                        }
                        observations.finished()
                        return result
                    } catch {
                        observations.failed(String(describing: error))
                        throw error
                    }
                }
                do {
                    let clock = ContinuousClock()
                    let deadline = clock.now + .seconds(10)
                    while !HeldRequestGate.isHolding, clock.now < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    if !HeldRequestGate.isHolding {
                        print("SETUP: load failure=\(String(describing: observations.snapshot().failure))")
                        let paths = StubURLProtocol.requests().map { $0.method + " " + $0.path }
                        print("SETUP: requests=\(paths)")
                    }
                    try #require(
                        HeldRequestGate.isHolding,
                        "SETUP: the real bridge must reach the held second metadata request")
                    let expected = Set((0..<500).map { PhotoUID(volumeID: "vol1", nodeID: "photo-\($0)") })
                    let beforeCompletion = observations.snapshot()
                    #expect(
                        beforeCompletion.pages.last == expected,
                        "The first qualified page must reach its observer before the second page completes")
                    #expect(beforeCompletion.pageCounts.last == expected.count, "No duplicates or estimated photos")
                    #expect(!beforeCompletion.completed, "An unfinished listing is not a complete load")
                    #expect(try store.load() == [old], "The old inventory remains authoritative while listing")
                    #expect(store.validationToken() == oldToken, "A page must not persist or advance the cache token")
                    let requests = StubURLProtocol.requests()
                    #expect(requests.allSatisfy { $0.method == "GET" }, "A provisional page performs no remote write")
                    #expect(!requests.contains { $0.path.contains("/trash") }, "No page-driven trash reconciliation")

                    Self.releaseSecondPage()
                    let completed = try await load.value
                    let finalUIDs = Set(completed.sections.flatMap(\.items).map(\.uid))
                    #expect(finalUIDs == expected.union([PhotoUID(volumeID: "vol1", nodeID: "last")]))
                    #expect(completed.sections.flatMap(\.items).count == 501)
                    #expect(observations.snapshot().completed)
                    #expect(Set(try store.load().map(\.uid)) == finalUIDs)
                    #expect(
                        store.validationToken()
                            == TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: "event-1"))
                } catch {
                    load.cancel()
                    Self.releaseSecondPage()
                    await bridge.shutdown()
                    _ = await load.result
                    throw error
                }
            }
        }

        @Test func cancellingOneObserverEndsItsWaitWhileTheOtherKeepsTheListing() async throws {
            try await withFixture { bridge, store, old, oldToken in
                let firstState = ProvisionalObservations()
                let secondState = ProvisionalObservations()
                let first = observedLoad(bridge, state: firstState)
                defer { first.cancel() }
                try #require(await eventually(timeout: .seconds(10)) { HeldRequestGate.isHolding })
                let second = observedLoad(bridge, state: secondState)
                defer { second.cancel() }
                try #require(await eventually(timeout: .seconds(10)) { secondState.snapshot().pageCounts.last == 500 })
                #expect(firstState.snapshot().pages.last == secondState.snapshot().pages.last)
                #expect(StubURLProtocol.requests().filter { $0.path.contains("/photos?") }.count == 1)
                first.cancel()
                #expect(
                    await eventually(timeout: .seconds(1)) { firstState.snapshot().failure != nil },
                    "Cancellation must end this observer's wait before the other caller releases page two")
                #expect(!secondState.snapshot().completed)
                #expect(HeldRequestGate.isHolding, "The other caller still owns the listing")
                #expect(try store.load() == [old])
                #expect(store.validationToken() == oldToken)
                Self.releaseSecondPage()
                await #expect(throws: CancellationError.self) { try await first.value }
                let completed = try await second.value
                #expect(completed.sections.flatMap(\.items).count == 501)
                #expect(secondState.snapshot().completed)
                #expect(firstState.snapshot().pageCounts == [500], "A cancelled observer gets no later page")
            }
        }

        @Test func aFailedPageKeepsTheCacheAndDoesNotReplayItsProjectionIntoTheNextLoad() async throws {
            try await withFixture { bridge, store, old, oldToken in
                let failedState = ProvisionalObservations()
                let failed = observedLoad(bridge, state: failedState)
                defer { failed.cancel() }
                try #require(await eventually(timeout: .seconds(10)) { HeldRequestGate.isHolding })
                try #require(await eventually(timeout: .seconds(10)) { failedState.snapshot().pageCounts.last == 500 })
                Self.releaseSecondPage(status: 403)
                await #expect(throws: (any Error).self) { try await failed.value }
                #expect(!failedState.snapshot().completed)
                #expect(try store.load() == [old])
                #expect(store.validationToken() == oldToken)
                #expect(!StubURLProtocol.requests().contains { $0.method != "GET" || $0.path.contains("/trash") })

                StubURLProtocol.route("GET /drive/volumes/vol1/photos", json: metadataResponse(prefix: "new"))
                let nextState = ProvisionalObservations()
                let next = observedLoad(bridge, state: nextState)
                defer { next.cancel() }
                try #require(await eventually(timeout: .seconds(10)) { HeldRequestGate.isHolding })
                let expected = Set((0..<500).map { PhotoUID(volumeID: "vol1", nodeID: "new-\($0)") })
                try #require(await eventually(timeout: .seconds(10)) { nextState.snapshot().pages.last == expected })
                #expect(nextState.snapshot().pages.allSatisfy { $0 == expected }, "No projection from the failed load")
                #expect(store.validationToken() == oldToken)
                Self.releaseSecondPage()
                let completed = try await next.value
                #expect(
                    Set(completed.sections.flatMap(\.items).map(\.uid))
                        == expected.union([
                            PhotoUID(volumeID: "vol1", nodeID: "last")
                        ]))
                #expect(StubURLProtocol.requests().filter { $0.path.contains("/photos?") }.count == 2)
            }
        }

        @Test func shutdownJoinsAnObserverBeforeClosingItsStore() async throws {
            try await withFixture { bridge, store, old, oldToken in
                let callback = ProvisionalCallbackHold()
                let state = ProvisionalObservations()
                let closed = ProvisionalObservations()
                let load = Task {
                    try await bridge.loadTimelineSnapshot { page in
                        state.received(page)
                        await withTaskCancellationHandler {
                            await callback.block()
                        } onCancel: {
                            state.cancelled()
                        }
                        state.recordStoreRead((try? store.load()) == [old] && store.validationToken() == oldToken)
                    }
                }
                defer { load.cancel() }
                var shutdown: Task<Void, Never>?
                do {
                    try #require(await eventually(timeout: .seconds(10)) { await callback.hasEntered() })
                    shutdown = Task {
                        await bridge.shutdown()
                        closed.finished()
                    }
                    try #require(await eventually(timeout: .seconds(10)) { state.snapshot().wasCancelled })
                    #expect(!closed.snapshot().completed, "Shutdown must join the held observer before store closure")
                    await callback.release()
                    await shutdown?.value
                    await #expect(throws: CancellationError.self) { try await load.value }
                    #expect(closed.snapshot().completed)
                    #expect(state.snapshot().storeReadWasSafe == true)
                    #expect(state.snapshot().pageCounts == [500], "Shutdown admits no later provisional page")
                } catch {
                    await callback.release()
                    await shutdown?.value
                    throw error
                }
            }
        }

        @Test func aSmallLibraryPublishesOnlyItsTenKnownPhotos() async throws {
            try await withFixture { bridge, store, _, _ in
                StubURLProtocol.route(
                    "GET /drive/volumes/vol1/photos", json: metadataResponse(prefix: "small", count: 10))
                let state = ProvisionalObservations()
                let completed = try await observedLoad(bridge, state: state).value
                let expected = Set((0..<10).map { PhotoUID(volumeID: "vol1", nodeID: "small-\($0)") })
                #expect(state.snapshot().pages == [expected])
                #expect(state.snapshot().pageCounts == [10])
                #expect(Set(completed.sections.flatMap(\.items).map(\.uid)) == expected)
                #expect(try store.load().count == 10)
                #expect(!HeldRequestGate.isHolding)
            }
        }

        @Test func matchingTokensWithEmptyUploadEvidenceRebuildLocally() async throws {
            try await withWarmEvidence([]) { bridge, store, volume, _ in
                let before = StubURLProtocol.requests().count
                StubURLProtocol.route(
                    "GET /drive/volumes/\(volume)/photos", json: metadataResponse(prefix: "unexpected", count: 1))

                let result = try await bridge.loadTimelineSnapshot()

                #expect(result.sections.flatMap(\.items).map(\.uid.nodeID) == ["listed-0"])
                #expect(StubURLProtocol.requests().dropFirst(before).allSatisfy { !$0.path.contains("/photos?") })
                #expect(try store.load().map(\.uid.nodeID) == ["listed-0"])
            }
        }

        @Test func matchingTokensWithUnlistedUploadEvidenceRequireAnAuthoritativeListing() async throws {
            try await withWarmEvidence(["n"]) { bridge, store, volume, _ in
                let before = StubURLProtocol.requests().count
                StubURLProtocol.route(
                    "GET /drive/volumes/\(volume)/photos",
                    json: StubbedLibrary.listingBody(["listed-0", "n"]))

                let result = try await bridge.loadTimelineSnapshot()

                #expect(Set(result.sections.flatMap(\.items).map(\.uid.nodeID)) == ["listed-0", "n"])
                #expect(StubURLProtocol.requests().dropFirst(before).contains { $0.path.contains("/photos?") })
                #expect(Set(try store.load().map(\.uid.nodeID)) == ["listed-0", "n"])
            }
        }

        @Test func anUnreadableUploadEvidenceReadListsAndKeepsEvidenceAfterSavingTheCache() async throws {
            try await withWarmEvidence(nil) { bridge, store, volume, fault in
                let before = StubURLProtocol.requests().count
                StubURLProtocol.route(
                    "GET /drive/volumes/\(volume)/photos", json: metadataResponse(prefix: "listed", count: 2))

                let result = try await bridge.loadTimelineSnapshot()

                #expect(Set(result.sections.flatMap(\.items).map(\.uid.nodeID)) == ["listed-0", "listed-1"])
                #expect(StubURLProtocol.requests().dropFirst(before).contains { $0.path.contains("/photos?") })
                #expect(fault?.lowered == true, "The display evidence read must arm the failed bind")
                #expect(fault?.stepped == true, "The cache transaction must restore the limit and run")
                fault?.remove()
                #expect(Set(try store.load().map(\.uid.nodeID)) == ["listed-0", "listed-1"], "The new cache was saved")
                #expect(
                    store.unmaterializedMediaTypeEvidenceNodeIDs(volumeID: volume) == ["n"],
                    "A failed evidence read must not authorize deletion of an upload's evidence")
            }
        }

        /// Warms the real bridge for one cursor, then changes local evidence while keeping that cursor unchanged.
        /// Nil injects a failed unmaterialized read after the complete display read. The next cache transaction
        /// restores the length limit, so the load can save successfully and exercise evidence cleanup.
        private func withWarmEvidence(
            _ evidence: Set<String>?,
            _ body: (DriveSDKBridge, TimelineMetadataStore, String, BindFailureUntilStep?) async throws -> Void
        ) async throws {
            let volume = String(repeating: "v", count: 3_000)
            try await withFixture(volumeID: volume) { bridge, store, _, _ in
                StubURLProtocol.route(
                    "GET /drive/volumes/\(volume)/photos", json: metadataResponse(prefix: "listed", count: 1))
                let first = try await bridge.loadTimelineSnapshot()
                try #require(first.sections.flatMap(\.items).map(\.uid.nodeID) == ["listed-0"])
                let token = TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: "event-1")
                try #require(store.validationToken() == token, "Warm the real cache with the matching cursor")
                try #require(store.relatedVideosChosen(by: LivePhotoMotionLinks.rule))
                let before = store.mediaTypeEvidenceRevision()
                let nodes = (evidence ?? ["n"]).union(["listed-0"])
                let types = Dictionary(
                    uniqueKeysWithValues: nodes.map { (PhotoUID(volumeID: volume, nodeID: $0), "image/jpeg") })
                try #require(store.recordMediaTypeEvidence(types).succeeded)
                try #require(store.mediaTypeEvidenceRevision() > before, "Make the local rebuild eligible")
                try #require(store.unmaterializedMediaTypeEvidenceNodeIDs(volumeID: volume) == (evidence ?? ["n"]))
                let fault: BindFailureUntilStep?
                if evidence == nil {
                    fault = try #require(
                        BindFailureUntilStep(
                            onStore: store, statement: "BEGIN IMMEDIATE",
                            after: "SELECT node, mime FROM media_type_evidence WHERE vol=?", limit: 2_048))
                } else {
                    fault = nil
                }
                defer { fault?.remove() }
                try await body(bridge, store, volume, fault)
            }
        }

        private func metadataResponse(prefix: String = "photo", count: Int = 500) -> String {
            StubbedLibrary.listingBody((0..<count).map { "\(prefix)-\($0)" })
        }

        /// Answers the held second Photos page: one more photo, or the failure `status`.
        private static func releaseSecondPage(status: Int = 200) {
            HeldRequestGate.release(
                status: status,
                body: status == 200
                    ? #"{"Code":1000,"Photos":[{"LinkID":"last","CaptureTime":1000,"Tags":[],"RelatedPhotos":[]}]}"#
                    : #"{"Code":\#(status)}"#)
        }

        private func observedLoad(
            _ bridge: DriveSDKBridge, state: ProvisionalObservations
        ) -> Task<TimelineLoadSnapshot, any Error> {
            Task {
                do {
                    let result = try await bridge.loadTimelineSnapshot { state.received($0) }
                    state.finished()
                    return result
                } catch {
                    state.failed(String(describing: error))
                    throw error
                }
            }
        }

        private func withFixture(
            volumeID: String = "vol1",
            _ body: (DriveSDKBridge, TimelineMetadataStore, PhotoItem, String) async throws -> Void
        ) async throws {
            StubURLProtocol.reset()
            HeldRequestGate.reset()
            HeldRequestGate.hold {
                $0.url?.path == "/drive/volumes/\(volumeID)/photos"
                    && $0.url?.query?.contains("PreviousPageLastLinkID=") == true
            }
            try await StubbedLibrary.withStore { directory, store in
                let old = PhotoItem(
                    uid: PhotoUID(volumeID: volumeID, nodeID: "old"),
                    captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/jpeg")
                let oldToken = TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: "event-0")
                #expect(store.save([old], validationToken: oldToken).succeeded)
                StubbedLibrary.routeShare(volumeID: volumeID)
                StubbedLibrary.routeEvents(from: 0, volumeID: volumeID)
                StubURLProtocol.route("GET /drive/volumes/\(volumeID)/photos", json: metadataResponse())
                let (bridge, _) = try await StubbedLibrary.makeBridge(
                    directory: directory, store: store, uid: "page-fixture",
                    protocols: [HeldRequestGate.self, StubURLProtocol.self])
                do {
                    try await body(bridge, store, old, oldToken)
                } catch {
                    Self.releaseSecondPage()
                    await bridge.shutdown()
                    throw error
                }
                Self.releaseSecondPage()
                await bridge.shutdown()
            }
        }
    }
}

private final class ProvisionalObservations: @unchecked Sendable {
    struct Snapshot {
        var pages: [Set<PhotoUID>] = []
        var pageCounts: [Int] = []
        var completed = false
        var failure: String?
        var storeReadWasSafe: Bool?
        var wasCancelled = false
    }
    private let lock = NSLock()
    private var value = Snapshot()

    func received(_ page: ProvisionalTimelineSnapshot) {
        lock.withLock {
            let items = page.sections.flatMap(\.items)
            value.pages.append(Set(items.map(\.uid)))
            value.pageCounts.append(items.count)
        }
    }

    func finished() { lock.withLock { value.completed = true } }
    func failed(_ error: String) { lock.withLock { value.failure = error } }
    func recordStoreRead(_ safe: Bool) { lock.withLock { value.storeReadWasSafe = safe } }
    func cancelled() { lock.withLock { value.wasCancelled = true } }
    func snapshot() -> Snapshot { lock.withLock { value } }
}

private actor ProvisionalCallbackHold {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func block() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func hasEntered() -> Bool { entered }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
