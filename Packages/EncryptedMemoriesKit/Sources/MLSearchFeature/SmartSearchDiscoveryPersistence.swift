import CryptoKit
import Foundation
import MLSearchCore
import PhotosCore

/// Completed presentation plus its checked evidence. No vectors, runtime authority, or session hashes.
struct SmartSearchDiscoveryPersistence: Codable, Sendable {
    // Bump for incompatible suggestion policy or sensitive-prompt changes.
    static let version = 1
    let version: Int
    let modelKey: String
    let fingerprint: Data
    let snapshot: SmartSearchDiscoveryModel.PersistedSnapshot
    let evidence: MLSearchBatchResults?
    /// Separates inventory changes from dates, favorites and place metadata. Missing values cannot
    /// authorize evidence reuse for different content, but an exact full fingerprint remains sufficient.
    var assetFingerprint: Data?

    /// Playback learns durations into SQLite although server timeline rows omit them.
    /// Discovery never reads duration, so that enrichment cannot change suggestion identity.
    static func suggestionItem(_ item: PhotoItem) -> PhotoItem {
        guard item.durationSeconds != nil else { return item }
        return PhotoItem(
            uid: item.uid, captureTime: item.captureTime, mediaType: item.mediaType,
            isLivePhoto: item.isLivePhoto, relatedVideoID: item.relatedVideoID,
            tags: item.tags, burstMemberIDs: item.burstMemberIDs)
    }

    static func assetFingerprint(sections: [TimelineSection]) throws -> Data {
        let items: [PhotoItem] = sections.flatMap(\.items)
        let uids: [PhotoUID] = items.map(\.uid).sorted { lhs, rhs in
            lhs.volumeID == rhs.volumeID ? lhs.nodeID < rhs.nodeID : lhs.volumeID < rhs.volumeID
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: try encoder.encode(uids)))
    }

    func hasCompleteEvidence(requiresVisualEvidence: Bool) -> Bool {
        // The sensitive gate applies only when visual search is enabled. Metadata-only rows are valid
        // without an embedding scan; the encrypted envelope and model key bind that policy.
        if !requiresVisualEvidence {
            return !snapshot.candidates.contains { $0.kind == .concept }
        }
        guard let evidence else {
            return !snapshot.candidates.contains { !$0.representativeUIDs.isEmpty || $0.kind == .concept }
        }
        let prompts = MLSearchConceptCatalog.suggestionPrompts
        guard evidence.results.count == prompts.count,
            Set(evidence.results.map(\.queryText)) == Set(prompts),
            let descriptor = evidence.results.first?.descriptor
        else { return false }
        return evidence.results.allSatisfy { $0.descriptor == descriptor }
            && snapshot.candidates.allSatisfy { row in
                row.representativeUIDs.allSatisfy { evidence.scannedUIDs.contains($0) }
            }
    }

    static func fingerprint(
        sections: [TimelineSection], favorites: Set<PhotoUID>, coordinates: [PhotoCoordinate],
        now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) throws -> Data {
        struct Content: Encodable {
            let items: [PhotoItem]
            let favorites: [PhotoUID]
            let coordinates: [PhotoCoordinate]
            let day: Date
            let calendar: String
            let timeZone: String
            let locale: String
        }
        func precedes(_ lhs: PhotoUID, _ rhs: PhotoUID) -> Bool {
            lhs.volumeID == rhs.volumeID ? lhs.nodeID < rhs.nodeID : lhs.volumeID < rhs.volumeID
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(
            Content(
                items: sections.flatMap(\.items).map(suggestionItem).sorted { precedes($0.uid, $1.uid) },
                favorites: favorites.sorted(by: precedes),
                coordinates: coordinates.sorted { precedes($0.uid, $1.uid) }, day: calendar.startOfDay(for: now),
                calendar: String(describing: calendar.identifier), timeZone: calendar.timeZone.identifier,
                locale: locale.identifier + "|" + Locale.preferredLanguages.joined(separator: "|")))
        return Data(SHA256.hash(data: data))
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }
}
