import Foundation
import PhotosCore

/// Decides how a completed timeline enumeration is published and cached.
/// A changed event token keeps the usable inventory but forces a later validation pass.
struct TimelineLoadCommitDecision: Equatable {
    /// Token stored beside the inventory. Nil keeps a partially enriched result memory-only.
    let persistedValidationToken: String?
    /// Baseline given to the shared change monitor. An empty value forces the next successful probe to refresh.
    let monitorBaseline: String
}

enum TimelineLoadCommitPolicy {
    static func decide(
        startEventToken: String,
        endEventToken: String,
        enrichmentComplete: Bool
    ) -> TimelineLoadCommitDecision {
        guard enrichmentComplete else {
            return TimelineLoadCommitDecision(
                persistedValidationToken: nil,
                monitorBaseline: ""
            )
        }
        guard startEventToken == endEventToken else {
            return TimelineLoadCommitDecision(
                persistedValidationToken: startEventToken,
                monitorBaseline: startEventToken
            )
        }
        return TimelineLoadCommitDecision(
            persistedValidationToken: endEventToken,
            monitorBaseline: endEventToken
        )
    }
}

enum TimelineInventorySource: Equatable {
    case sdkCache
    case authoritativePhotosList
}

/// Versioned envelope for the event token paired with a persisted Photos inventory. A contract bump invalidates
/// only fast-path validation and forces one authoritative listing; the cached rows remain visible while it runs.
enum TimelineInventoryValidationTokenPolicy {
    private static let prefix = "photos-inventory-v2:"

    static func persistedToken(remoteEventToken: String) -> String {
        prefix + remoteEventToken
    }

    static func remoteEventToken(from persistedToken: String?) -> String? {
        guard let persistedToken else { return nil }
        guard persistedToken.hasPrefix(prefix) else { return persistedToken }
        return String(persistedToken.dropFirst(prefix.count))
    }
}

enum TimelineInventoryVisibilityError: LocalizedError, TimelineInventoryConvergenceError {
    case pendingUploadsNotVisible(Int)
    case remoteChangesNotVisible(Int)

    var errorDescription: String? {
        switch self {
        case .pendingUploadsNotVisible(let count):
            "The server listing has not exposed \(count) completed upload(s) yet."
        case .remoteChangesNotVisible(let count):
            "The server listing has not exposed \(count) remotely changed photo(s) yet."
        }
    }
}

/// Keeps the SDK's cached enumeration on unchanged loads, but bypasses it after a known server mutation.
enum TimelineInventorySourcePolicy {
    static func decide(
        cachedEventToken: String?,
        currentEventToken: String,
        hasPendingLocalUploads: Bool,
        hasUnmaterializedLocalEvidence: Bool
    ) -> TimelineInventorySource {
        if hasPendingLocalUploads || hasUnmaterializedLocalEvidence { return .authoritativePhotosList }
        guard let cachedEventToken else { return .sdkCache }
        return cachedEventToken == currentEventToken ? .sdkCache : .authoritativePhotosList
    }
}

enum TimelineRemoteEventVisibilityPolicy {
    static func apply(
        _ events: [VolumeEventPage.Item],
        photosShareID: String,
        to activeNodeIDs: inout Set<String>
    ) {
        for event in events {
            if event.eventType == 0 {
                activeNodeIDs.remove(event.linkID)
            } else if event.contextShareID == photosShareID,
                event.linkState != 0,
                event.linkType == nil || event.linkType == 2,
                event.linkState == nil || event.linkState == 1
            {
                activeNodeIDs.insert(event.linkID)
            }
        }
    }
}
