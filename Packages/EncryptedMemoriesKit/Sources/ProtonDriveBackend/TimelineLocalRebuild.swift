import Foundation
import PhotosCore

/// The two local revisions that the foreground change token carries behind the server's event cursor: the
/// published media-type evidence and the published order evidence.
struct TimelineLocalRevisions: Equatable, Sendable {
    let mediaType: Int
    let order: Int
}

/// What the last persisted timeline load of this backend was built from: the server event cursor of the listing and
/// the local revisions that were current when its sections were grouped.
struct TimelineLoadBasis: Equatable, Sendable {
    let eventToken: String
    let revisions: TimelineLocalRevisions
}

/// Rebuilds the timeline from the local store when only local evidence changed since the last load.
///
/// A media-type or order revision changes the foreground change token, although the server's event cursor is the
/// same. A load then enumerated the whole library again (SDK enumeration, three tag listings) to apply that local
/// evidence. The stored inventory is the result of the last load for that same cursor, so applying the evidence to it
/// gives the same sections without a listing. Every other situation keeps the existing sources.
enum TimelineLocalRebuild {
    /// The facts that decide whether the stored inventory can stand in for a listing.
    struct Conditions {
        let basis: TimelineLoadBasis?
        let currentEventToken: String
        let currentRevisions: TimelineLocalRevisions
        let hasPendingLocalUploads: Bool
        let hasUnmaterializedLocalEvidence: Bool
        let hasPhotosAwaitingLibrary: Bool
        let continuityRecoveryRequired: Bool
    }

    /// Whether the stored inventory may be used. All of these must hold:
    /// - the last persisted load of this backend ran for the same server event cursor;
    /// - only a local revision differs from that load (a load with nothing changed keeps the existing source);
    /// - the stored inventory carries the validation token of that cursor, so it is the result of that load;
    /// - no upload, local evidence, trash wait or continuity recovery needs a listing.
    static func isEligible(_ conditions: Conditions, storedValidationToken: String?) -> Bool {
        guard !conditions.hasPendingLocalUploads, !conditions.hasUnmaterializedLocalEvidence,
            !conditions.hasPhotosAwaitingLibrary, !conditions.continuityRecoveryRequired,
            let basis = conditions.basis,
            basis.eventToken == conditions.currentEventToken,
            basis.revisions != conditions.currentRevisions
        else { return false }
        return storedValidationToken
            == TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: conditions.currentEventToken)
    }

    /// The sections to publish, or nil when the existing sources must run. The store reads happen only when the
    /// conditions hold, and a failed or empty read gives nil, so a damaged store never replaces a listing.
    static func plan(
        _ conditions: Conditions,
        storedValidationToken: () -> String?,
        storedItems: () throws -> [PhotoItem]?,
        mediaTypeEvidence: () -> [String: String]
    ) -> [TimelineSection]? {
        guard isEligible(conditions, storedValidationToken: storedValidationToken()) else { return nil }
        guard let stored = try? storedItems(), !stored.isEmpty else { return nil }
        return sections(from: stored, mediaTypeEvidence: mediaTypeEvidence())
    }

    /// The stored items with the media-type evidence applied, grouped like a listing: one section, canonical order,
    /// no duration (a listing enumerates none, and a save keeps the durations learned later).
    static func sections(from stored: [PhotoItem], mediaTypeEvidence: [String: String]) -> [TimelineSection] {
        let items =
            stored
            .map { item -> PhotoItem in
                let mediaType = mediaTypeEvidence[item.uid.nodeID] ?? item.mediaType
                var tags = item.tags
                tags.remove(.videos)
                if mediaType.hasPrefix("video/") { tags.insert(.videos) }
                return PhotoItem(
                    uid: item.uid,
                    captureTime: item.captureTime,
                    mediaType: mediaType,
                    isLivePhoto: item.isLivePhoto,
                    relatedVideoID: item.relatedVideoID,
                    tags: tags,
                    burstMemberIDs: item.burstMemberIDs)
            }
            .sorted(by: TimelineOrder.areInIncreasingOrder)
        return [TimelineSection(id: "all", date: items.first?.captureTime ?? .distantPast, title: "", items: items)]
    }
}
