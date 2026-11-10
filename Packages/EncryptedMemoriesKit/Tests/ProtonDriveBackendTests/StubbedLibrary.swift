import Foundation
import PhotosCore
import ProtonAuth
import Testing

@testable import ProtonDriveBackend

/// The Proton routes and the bridge that the library tests over `StubURLProtocol` share: one photos share on one
/// volume, an event feed that moves from one event to the next, and a photos listing that holds the given links.
enum StubbedLibrary {
    /// A temporary directory with an empty timeline store; both are removed when `body` ends.
    static func withStore<T>(_ body: (URL, TimelineMetadataStore) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        return try await body(directory, store)
    }

    static func routeShare() {
        StubURLProtocol.route(
            "GET /drive/shares",
            json: #"{"Code":1000,"Shares":[{"ShareID":"share1","VolumeID":"vol1","LinkID":"root","State":1}]}"#)
    }

    /// The feed moves from event `from` to `from + 1`. The SDK reads only the cursor of the version 2 feed; the app
    /// reads the removals from the first one.
    static func routeEvents(from: Int, removed: [String] = []) {
        let to = from + 1
        let events = removed.map {
            #"{"EventType":2,"ContextShareID":"share1","Link":{"LinkID":"\#($0)","Type":2,"State":2}}"#
        }.joined(separator: ",")
        StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"event-\#(to)"}"#)
        StubURLProtocol.route(
            "GET /drive/volumes/vol1/events/event-\(from)",
            json: #"{"Code":1000,"EventID":"event-\#(to)","More":0,"Refresh":0,"Events":[\#(events)]}"#)
        for cursor in [from, to] {
            StubURLProtocol.route(
                "GET /drive/v2/volumes/vol1/events/event-\(cursor)",
                json: #"{"Code":1000,"EventID":"event-\#(to)","More":false,"Refresh":false,"Events":[]}"#)
        }
        StubURLProtocol.route(
            "GET /drive/volumes/vol1/events/event-\(to)",
            json: #"{"Code":1000,"EventID":"event-\#(to)","More":0,"Refresh":0,"Events":[]}"#)
    }

    /// A photos listing page of these links, captured one second apart from the tenth second on.
    static func listingBody(_ ids: [String]) -> String {
        let page = ids.enumerated().map {
            #"{"LinkID":"\#($0.element)","CaptureTime":\#($0.offset + 10),"Tags":[],"RelatedPhotos":[]}"#
        }.joined(separator: ",")
        return #"{"Code":1000,"Photos":[\#(page)]}"#
    }

    /// A bridge over `store` whose requests go through `protocols`, with the first index build started.
    static func makeBridge(
        directory: URL, store: TimelineMetadataStore, uid: String, protocols: [AnyClass]
    ) async throws -> (bridge: DriveSDKBridge, governor: ProtonRequestGovernor) {
        let governor = ProtonRequestGovernor()
        let session = DriveSession(
            session: ProtonSession(uid: uid, accessToken: "", refreshToken: "", keyPassword: ""),
            store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
            accountCacheDirectory: directory, requestGovernor: governor, urlProtocolClasses: protocols)
        let bridge = try await DriveSDKBridge.testBridge(
            directory: directory, session: session, governor: governor, protocols: protocols,
            timelineStore: store, startsFirstBuild: true)
        return (bridge, governor)
    }
}
