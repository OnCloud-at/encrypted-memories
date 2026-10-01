import Foundation

/// Only code-owned load paths and error categories can enter a library support report.
public struct LibrarySyncSupportSnapshot: Codable, Sendable, Equatable {
    public enum SourcePath: String, Codable, Sendable {
        case preparation, authoritative, continuity, sdkCache, cache
    }

    public enum ErrorKind: String, Codable, Sendable {
        case cancellation, continuityPending, inventoryVisibility, scopeAccessLost, network, sdk, unknown
    }

    public struct Load: Codable, Sendable, Equatable {
        public let timestamp: Date
        public let sourcePath: SourcePath
        public let errorKind: ErrorKind?

        public init(timestamp: Date, sourcePath: SourcePath, errorKind: ErrorKind? = nil) {
            self.timestamp = timestamp
            self.sourcePath = sourcePath
            self.errorKind = errorKind
        }
    }

    public var lastSuccessfulLoad: Load?
    public var lastFailedLoad: Load?
    public var storedEventCursorAgeSeconds: TimeInterval?
    public var storedPhotoCount: Int?
    public var listedPhotoCount: Int?
    public var photosTrashedHereAwaitingLibrary: Int?

    public init(
        lastSuccessfulLoad: Load? = nil, lastFailedLoad: Load? = nil,
        storedEventCursorAgeSeconds: TimeInterval? = nil, storedPhotoCount: Int? = nil,
        listedPhotoCount: Int? = nil, photosTrashedHereAwaitingLibrary: Int? = nil
    ) {
        self.lastSuccessfulLoad = lastSuccessfulLoad
        self.lastFailedLoad = lastFailedLoad
        self.storedEventCursorAgeSeconds = storedEventCursorAgeSeconds
        self.storedPhotoCount = storedPhotoCount
        self.listedPhotoCount = listedPhotoCount
        self.photosTrashedHereAwaitingLibrary = photosTrashedHereAwaitingLibrary
    }
}

public struct BackupQueueSupportSnapshot: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case discovered, checking, hashing, duplicateChecking, queuedForUpload, uploading, finalizing
        case needsRemoteReconciliation, alreadyBackedUp, completed, skippedRemoteDeletion, sourceMissing
        case blockedByDraft, failed, failedPermanent, dismissedFailure, paused, unknown
    }

    public enum ResourceKind: String, Codable, Sendable, CaseIterable {
        case primary, livePairedVideo, originalPhoto, alternatePhoto, fullSizePhoto, originalVideo, audio
        case fullSizeVideo, pairedVideo, fullSizePairedVideo, adjustmentData, adjustmentBasePhoto
        case adjustmentBaseVideo, adjustmentBasePairedVideo, photoProxy, burstMember, burstMainReference, other
    }

    public enum Reason: String, Codable, Sendable, CaseIterable {
        case none, unclassified, network, deviceStorage, remoteDraft, remoteDraftStale, sourceMissing
        case permission, unsupported, remoteService, localState, remoteDeletion, accountStorage, unknown
    }

    public struct StateCount: Codable, Sendable, Equatable {
        public let state: State
        public let count: Int
        public init(state: State, count: Int) {
            self.state = state
            self.count = count
        }
    }

    public struct ResourceCount: Codable, Sendable, Equatable {
        public let resourceKind: ResourceKind
        public let count: Int
        public init(resourceKind: ResourceKind, count: Int) {
            self.resourceKind = resourceKind
            self.count = count
        }
    }

    public struct ReasonCount: Codable, Sendable, Equatable {
        public let reason: Reason
        public let count: Int
        public init(reason: Reason, count: Int) {
            self.reason = reason
            self.count = count
        }
    }

    public var isAvailable = false
    public var total = 0
    public var countsByState: [StateCount] = []
    public var countsByResourceKind: [ResourceCount] = []
    public var waitingByReason: [ReasonCount] = []
    public var parkedByReason: [ReasonCount] = []

    public init() {}
}

public struct EditReplacementSupportSnapshot: Codable, Sendable, Equatable {
    public var sourcesWithSupersededEntries = 0
    public var totalSuperseded = 0
    public var totalRetired = 0
    public var rowsWithRetireIntent = 0

    public init() {}
}

/// Sources expose only allowlisted values. Export never asks them to refresh remote state.
public protocol LibrarySyncSupportSource: AnyObject, Sendable {
    func librarySyncSupportSnapshot(now: Date) async -> LibrarySyncSupportSnapshot?
}

public protocol BackupQueueSupportSource: AnyObject, Sendable {
    func backupSupportSnapshot() -> BackupQueueSupportSnapshot
}

public protocol EditReplacementSupportSource: AnyObject, Sendable {
    func editReplacementSupportSnapshot() -> EditReplacementSupportSnapshot
}
