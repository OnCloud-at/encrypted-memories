import Foundation
import PhotosCore
import UploadCore

/// Fills the file name index from `links/fetch_metadata` responses.
///
/// The timeline metadata pass hands over the names of the links it read anyway. A library that finished its pass
/// before names were kept gets one backfill: the photos without a stored name, 150 per request, at maintenance
/// priority. Each batch commits on its own, so an app end loses at most the batch in flight.
enum PhotoNameFill {
    struct Outcome: Equatable, Sendable {
        var requests = 0
        var recorded = 0
        /// The backfill stopped before it covered every photo: the runtime withdrew permission.
        var deferred = false
    }

    /// The names of the requested links of one response, by photo. A name that does not decrypt is recorded empty,
    /// so that photo is not requested again until an event changes it.
    static func names(
        in links: [AlbumPhotoLinkBody], requested: Set<String>, volumeID: String, decrypt: (String) -> String?
    ) -> [PhotoUID: String] {
        var names: [PhotoUID: String] = [:]
        for link in links {
            guard let linkID = link.linkID, requested.contains(linkID) else { continue }
            names[PhotoUID(volumeID: volumeID, nodeID: linkID)] = link.name.flatMap(decrypt) ?? ""
        }
        return names
    }

    /// The backfill reads only while the app is active in the foreground on a reachable network that is neither
    /// constrained (Low Data Mode) nor expensive (cellular or a personal hotspot).
    static func permits(_ runtime: LibraryRuntimeSnapshot) -> Bool {
        let network = runtime.network
        return runtime.executionOpportunity == .foregroundActive && network.isDetermined && network.isReachable
            && !network.isConstrained && !network.isExpensive
    }

    /// Reads the names of the given photos that have no stored name. It stops without an error when `permits`
    /// turns false and continues in a later pass. `nameKey` is asked once, before the first request, and only when
    /// a name is missing; nil (the key is unavailable) ends the backfill for this pass.
    static func backfill(
        nodeIDs: [String],
        volumeID: String,
        store: PhotoNameStore,
        permits: () -> Bool,
        nameKey: () async throws -> ((String) -> String?)?,
        fetch: ([String]) async throws -> [AlbumPhotoLinkBody],
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Outcome {
        var outcome = Outcome()
        guard let recorded = store.recordedNodeIDs(volumeID: volumeID) else { return outcome }
        let missing = Array(Set(nodeIDs).subtracting(recorded)).sorted()
        let size = UploadDedupePipeline.protonDuplicateBatchSize
        var decrypt: ((String) -> String?)?
        for start in stride(from: 0, to: missing.count, by: size) {
            try Task.checkCancellation()
            guard permits() else {
                outcome.deferred = true
                return outcome
            }
            if decrypt == nil { decrypt = try await nameKey() }
            guard let decrypt else { return outcome }
            let batch = Array(missing[start..<min(start + size, missing.count)])
            let links = try await ProtonRequestContext.$priority.withValue(.maintenance) {
                try await fetch(batch)
            }
            outcome.requests += 1
            try Task.checkCancellation()
            var names = Self.names(in: links, requested: Set(batch), volumeID: volumeID, decrypt: decrypt)
            // A photo that the response lacks has no readable name now; an event or rename brings it back.
            for nodeID in batch where names[PhotoUID(volumeID: volumeID, nodeID: nodeID)] == nil {
                names[PhotoUID(volumeID: volumeID, nodeID: nodeID)] = ""
            }
            guard store.record(names) else { throw PhotoNameFillError.storeUnavailable }
            outcome.recorded += names.count
            await Task.yield()
        }
        return outcome
    }
}

enum PhotoNameFillError: Error {
    case storeUnavailable
}
