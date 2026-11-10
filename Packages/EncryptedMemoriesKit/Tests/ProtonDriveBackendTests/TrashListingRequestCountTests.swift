import Foundation
import PhotosCore
import ProtonAuth
import Testing

@testable import ProtonDriveBackend

/// What a library load, an idle probe and an own trash send to Proton, counted by cause and endpoint (#1099).
///
/// The counts come from the request governor of the real bridge. Every number below was measured first; a test fails
/// when a change adds a request or drops one that must stay. A photo trashed on this device leaves the stored timeline
/// when the trash write succeeds, so the next load never sweeps it and never lists the trash before it publishes. A
/// photo that another device trashed is swept, and the load lists the trash first so its thumbnail stays.
extension DriveSessionStubSuite {
    @Suite struct TrashListingRequestCountTests {
        @Test func anOwnTrashListsTheTrashOnlyInTheBackground() async throws {
            try await Fixture.run { fixture in
                let own = fixture.uids(0..<3)
                let beforeTrash = await fixture.counts()
                try await fixture.trash(own)
                let write = await fixture.since(beforeTrash)
                #expect(write == [Fixture.trashWrite: 1], "one write, no listing")
                #expect(try fixture.storedPhotoCount() == Fixture.libraryCount - 3, "the write removes the stored rows")

                let before = await fixture.counts()
                try await fixture.load(listing: fixture.ids(3..<100), trash: own, removedAt: 1, removed: own)
                let sync = await fixture.since(before)
                #expect(
                    sync[Fixture.syncTrashPage] == nil, "an own trash is never swept, so no listing runs before publish"
                )
                #expect(sync[Fixture.syncTrashMetadata] == nil)

                #expect(
                    await eventually(timeout: .seconds(10)) {
                        await fixture.since(before)[Fixture.backgroundTrashPage] == 1
                    })
                try await fixture.waitForRequestsToSettle()
                let settled = await fixture.since(before)
                #expect(settled[Fixture.backgroundTrashPage] == 1, "the listing that ends the own trash runs once")
                #expect(settled[Fixture.backgroundTrashMetadata] == 1, "one metadata batch for up to 150 trashed links")
                #expect(settled[Fixture.syncTrashPage] == nil)
            }
        }

        @Test func aRemovalOnAnotherDeviceListsTheTrashBeforePublishing() async throws {
            try await Fixture.run { fixture in
                let elsewhere = fixture.uids(0..<2)
                let before = await fixture.counts()
                try await fixture.load(
                    listing: fixture.ids(2..<100), trash: elsewhere, removedAt: 1, removed: elsewhere)
                let sync = await fixture.since(before)
                #expect(sync[Fixture.syncTrashPage] == 1, "the load lists the trash itself, before it returns")
                #expect(sync[Fixture.syncTrashMetadata] == 1)
                #expect(sync[Fixture.backgroundTrashPage] == nil)
                #expect(try fixture.storedPhotoCount() == Fixture.libraryCount - 2)

                try await fixture.waitForRequestsToSettle()
                let settled = await fixture.since(before)
                #expect(settled[Fixture.backgroundTrashPage] == nil, "no second listing follows")
            }
        }

        @Test func aMixedRemovalListsTheTrashOnce() async throws {
            try await Fixture.run { fixture in
                let own = fixture.uids(0..<3)
                let elsewhere = fixture.uids(10..<12)
                try await fixture.trash(own)
                let before = await fixture.counts()
                try await fixture.load(
                    listing: fixture.ids(3..<100).filter { !["p10", "p11"].contains($0) }, trash: own + elsewhere,
                    removedAt: 1, removed: own + elsewhere)
                let sync = await fixture.since(before)
                #expect(sync[Fixture.syncTrashPage] == 1)
                #expect(sync[Fixture.syncTrashMetadata] == 1)
                #expect(try fixture.storedPhotoCount() == Fixture.libraryCount - 5)

                try await fixture.waitForRequestsToSettle()
                let settled = await fixture.since(before)
                #expect(settled[Fixture.backgroundTrashPage] == nil, "the listing of the load already ended the wait")
            }
        }

        @Test func aTrashThatEndsDuringALoadNeverBringsItsPhotoBack() async throws {
            try await Fixture.run { fixture in
                let photo = fixture.uids(0..<1)
                // The listing that the load reads still returns the photo; the trash write ends while it is held.
                fixture.advanceEvents(from: 1, removed: [])
                HeldRequestGate.hold { $0.url?.path == "/drive/volumes/vol1/photos" }
                let before = await fixture.counts()
                let loading = Task { try await fixture.bridge.loadTimelineSnapshot { _ in } }
                #expect(await eventually(timeout: .seconds(10)) { HeldRequestGate.isHolding })
                try await fixture.trash(photo)
                HeldRequestGate.release(body: StubbedLibrary.listingBody(fixture.ids(0..<100)))
                HeldRequestGate.reset()
                _ = try await loading.value
                #expect(try fixture.storedPhotos().contains { $0.uid == photo[0] } == false)
                let sync = await fixture.since(before)
                #expect(sync[Fixture.syncTrashPage] == nil, "the load that raced the write lists nothing first")

                try await fixture.waitForRequestsToSettle()
                let beforeNext = await fixture.counts()
                try await fixture.load(listing: fixture.ids(1..<100), trash: photo, removedAt: 2, removed: photo)
                let next = await fixture.since(beforeNext)
                #expect(next[Fixture.syncTrashPage] == nil, "the photo was never swept, so no listing runs first")
                #expect(try fixture.storedPhotos().contains { $0.uid == photo[0] } == false)
            }
        }

        @Test func anIdleProbeSendsOneEventRequest() async throws {
            try await Fixture.run { fixture in
                let before = await fixture.counts()
                for _ in 0..<10 { _ = try await fixture.bridge.libraryChangeToken() }
                #expect(await fixture.since(before) == [Fixture.probe: 10], "one request per probe, nothing else")
            }
        }
    }
}

/// The real bridge over stubbed Proton routes. The library holds 100 photos, `p0` to `p99`, after the first load.
private struct Fixture {
    static let libraryCount = 100
    static let trashWrite = "trash.write POST /drive/v2/volumes/{id}/trash_multiple"
    static let syncTrashPage = "timeline.full GET /drive/volumes/{id}/trash"
    static let syncTrashMetadata = "timeline.full POST /drive/shares/{id}/links/fetch_metadata"
    static let backgroundTrashPage = "trash.list GET /drive/volumes/{id}/trash"
    static let backgroundTrashMetadata = "trash.list POST /drive/shares/{id}/links/fetch_metadata"
    static let probe = "timeline.probe GET /drive/v2/volumes/{id}/events/{id}"

    let bridge: DriveSDKBridge
    let store: TimelineMetadataStore
    let governor: ProtonRequestGovernor

    static func run(_ body: (Fixture) async throws -> Void) async throws {
        StubURLProtocol.reset()
        HeldRequestGate.reset()
        try await StubbedLibrary.withStore { directory, store in
            StubbedLibrary.routeShare()
            StubbedLibrary.routeEvents(from: 0)
            routeTrash([])
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/photos", json: StubbedLibrary.listingBody((0..<libraryCount).map { "p\($0)" }))
            let (bridge, governor) = try await StubbedLibrary.makeBridge(
                directory: directory, store: store, uid: "trash-count",
                protocols: [HeldRequestGate.self, StubURLProtocol.self])
            let fixture = Fixture(bridge: bridge, store: store, governor: governor)
            do {
                _ = try await bridge.loadTimelineSnapshot { _ in }
                try await fixture.waitForRequestsToSettle()
                try await body(fixture)
            } catch {
                HeldRequestGate.reset()
                await bridge.shutdown()
                throw error
            }
            await bridge.shutdown()
        }
    }

    func ids(_ range: Range<Int>) -> [String] { range.map { "p\($0)" } }
    func uids(_ range: Range<Int>) -> [PhotoUID] { range.map { PhotoUID(volumeID: "vol1", nodeID: "p\($0)") } }
    func storedPhotos() throws -> [PhotoItem] { try store.load() }
    func storedPhotoCount() throws -> Int { try store.load().count }

    func trash(_ photos: [PhotoUID]) async throws {
        let answers = photos.map { #"{"LinkID":"\#($0.nodeID)","Response":{"Code":1000}}"# }.joined(separator: ",")
        StubURLProtocol.route(
            "POST /drive/v2/volumes/vol1/trash_multiple", json: #"{"Code":1001,"Responses":[\#(answers)]}"#)
        try await bridge.trash(photos)
    }

    /// One library load after the server moved from event `removedAt` to the next one. `listing` is what the photos
    /// listing returns, `trash` what the trash lists, `removed` what the event feed shows as removed.
    func load(listing: [String], trash: [PhotoUID], removedAt: Int, removed: [PhotoUID]) async throws {
        StubURLProtocol.route("GET /drive/volumes/vol1/photos", json: StubbedLibrary.listingBody(listing))
        Self.routeTrash(trash.map(\.nodeID))
        advanceEvents(from: removedAt, removed: removed)
        _ = try await bridge.loadTimelineSnapshot { _ in }
    }

    func advanceEvents(from: Int, removed: [PhotoUID]) {
        StubbedLibrary.routeEvents(from: from, removed: removed.map(\.nodeID))
    }

    func counts() async -> [String: Int] {
        var result: [String: Int] = [:]
        for count in await governor.requestSupportSnapshot().counts {
            result["\(count.cause) \(count.method) \(count.endpoint)", default: 0] += count.count
        }
        return result
    }

    /// The requests sent since `before`, by cause, method and endpoint; unchanged keys are left out.
    func since(_ before: [String: Int]) async -> [String: Int] {
        var result: [String: Int] = [:]
        for (key, count) in await counts() where count > (before[key] ?? 0) { result[key] = count - (before[key] ?? 0) }
        return result
    }

    /// Waits until a background listing or reconciliation sends no request for 150 ms. The bridge offers no way to join
    /// its background work, so a request that comes later than that is not seen: a test that expects "no further
    /// request" after this wait pins the stub timing of a normal run, and a mutation shows it fails when one is added.
    func waitForRequestsToSettle() async throws {
        var last = -1
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(150))
            let now = StubURLProtocol.requests().count
            if now == last { return }
            last = now
        }
        Issue.record("requests did not settle")
    }

    private static func routeTrash(_ ids: [String]) {
        let quoted = ids.map { "\"\($0)\"" }.joined(separator: ",")
        let group = ids.isEmpty ? "" : #"{"ShareID":"share1","LinkIDs":[\#(quoted)]}"#
        StubURLProtocol.route("GET /drive/volumes/vol1/trash", json: #"{"Code":1000,"Trash":[\#(group)]}"#)
        let links = ids.map {
            #"{"LinkID":"\#($0)","Type":2,"CreateTime":5,"MIMEType":"image/jpeg","FileProperties":{"ActiveRevision":{"Photo":{"CaptureTime":5}}}}"#
        }.joined(separator: ",")
        StubURLProtocol.route(
            "POST /drive/shares/share1/links/fetch_metadata", json: #"{"Code":1000,"Links":[\#(links)]}"#)
    }
}
