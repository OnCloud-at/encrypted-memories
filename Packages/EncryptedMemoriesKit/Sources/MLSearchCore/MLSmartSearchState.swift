import Foundation

/// A user-recoverable Smart Search failure. `isRetryable` gates the UI retry action.
public struct MLSmartSearchFailure: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case catalog
        case download
        case verification
        case installation
        case modelLoad
        case storage
        /// The device has too little free space for the model download.
        case insufficientStorage
    }

    public let kind: Kind
    public let isRetryable: Bool
    /// Diagnostic detail for logs; UI copy comes from the presentation layer per `kind`.
    public let debugDescription: String
    /// Free space the failed step needs, including its reserve, when the failure is about space.
    public let requiredBytes: Int64?

    public init(kind: Kind, isRetryable: Bool, debugDescription: String, requiredBytes: Int64? = nil) {
        self.kind = kind
        self.isRetryable = isRetryable
        self.debugDescription = debugDescription
        self.requiredBytes = requiredBytes
    }
}

/// Shared model distribution and runtime state. Index progress is tracked independently in
/// `MLSmartSearchIndexingState`, so native analysis does not depend on a downloaded model.
public enum MLSmartSearchPhase: Sendable, Equatable {
    case disabled
    /// Refreshing the signed list of downloadable models.
    case loadingCatalog
    /// The catalog is ready and the user must choose a model before any download starts.
    case selectingModel
    /// Enabled with a selected model whose artifacts are not installed (and, when
    /// `downloadable` is false, cannot be fetched automatically).
    case notInstalled(downloadable: Bool)
    case downloading(MLModelTransferProgress)
    case verifying
    case installing
    /// Model artifacts installed; the runtime session (CoreML compile/load) is being prepared.
    case preparingModel
    case indexing(MLIndexProgress)
    /// Installed but catch-up is paused by resource policy or a transient failure.
    case waiting(MLIndexCoverage)
    /// Installed and idle with every asset accounted for.
    case ready(MLIndexCoverage)
    case switchingModel(to: MLModelID)
    case deleting
    case failed(MLSmartSearchFailure)

    public var isBusy: Bool {
        switch self {
        case .loadingCatalog, .downloading, .verifying, .installing, .preparingModel, .switchingModel, .deleting:
            return true
        case .disabled, .selectingModel, .notInstalled, .indexing, .waiting, .ready, .failed:
            return false
        }
    }
}

/// Aggregate progress across every enabled Smart Search backend.
///
/// The counters are work units, not photo counts. A semantic embedding and each independently
/// durable native artifact are separate units, so presenting them as photos would be misleading.
/// Keeping the aggregation in Core gives every host one truthful status without exposing pipeline
/// implementation details in platform UI.
public struct MLSmartSearchAggregateProgress: Sendable, Equatable {
    public let totalWorkUnits: Int
    public let settledWorkUnits: Int
    /// Unfinished native work with a scheduled retry, not work in the initial indexing queue.
    public let deferredWorkUnits: Int
    public let permanentlyUnavailableAssets: Int
    public let unavailableAssetReasons: [MLPipelineFailureReason: Int]

    public init(
        totalWorkUnits: Int,
        settledWorkUnits: Int,
        permanentlyUnavailableAssets: Int,
        unavailableAssetReasons: [MLPipelineFailureReason: Int] = [:],
        deferredWorkUnits: Int = 0
    ) {
        self.totalWorkUnits = max(0, totalWorkUnits)
        self.settledWorkUnits = min(max(0, settledWorkUnits), max(0, totalWorkUnits))
        self.deferredWorkUnits = min(max(0, deferredWorkUnits), self.totalWorkUnits - self.settledWorkUnits)
        self.permanentlyUnavailableAssets = max(0, permanentlyUnavailableAssets)
        self.unavailableAssetReasons = unavailableAssetReasons.filter { $0.value > 0 }
    }

    public var fraction: Double? {
        totalWorkUnits > 0 ? Double(settledWorkUnits) / Double(totalWorkUnits) : nil
    }
    public var isComplete: Bool { settledWorkUnits == totalWorkUnits }
}

/// User-facing indexing state shared by native analysis and the optional semantic model.
/// Model download/install state stays independent in `MLSmartSearchPhase`.
public enum MLSmartSearchIndexingState: Sendable, Equatable {
    case idle
    case indexing(MLSmartSearchAggregateProgress)
    case waiting(MLSmartSearchAggregateProgress)
    case ready(MLSmartSearchAggregateProgress)
    case failed(MLSmartSearchFailure)
}

/// Full state snapshot emitted to hosts after every transition.
public struct MLSmartSearchSnapshot: Sendable, Equatable {
    /// `false` when this device or product tier cannot run Smart Search; it then cannot be turned on.
    public let isSupported: Bool
    /// Smart Search runs native Apple Vision analysis and the selected semantic model together.
    public let isEnabled: Bool
    /// The semantic model. `nil` while enabled only when the selection must be made again, for
    /// example after the catalog dropped the selected model.
    public let selectedModelID: MLModelID?
    public let phase: MLSmartSearchPhase
    /// Installed size of the active model in bytes (0 when nothing is installed).
    public let installedModelBytes: Int64
    /// A model was activated and owns an index, even while its session is not loaded, for example after a failed
    /// model load. Replacing it rebuilds that index.
    public let hasActivatedModel: Bool
    /// A switch-on waits for the model list; Smart Search then starts with the recommended model.
    public let isStartPending: Bool
    /// The last switch-on or switch-off intent the lifecycle applied. Hosts keep showing the person's newer intent
    /// until a snapshot with that number arrives.
    public let startIntent: UInt64
    /// Selectable catalog entries for this environment.
    public let availableModels: [MLModelCatalogEntry]
    /// `true` once any enabled backend has searchable coverage.
    public let isSearchAvailable: Bool
    /// One Core-owned status for all enabled indexing pipelines.
    public let indexingState: MLSmartSearchIndexingState

    public init(
        isSupported: Bool = true,
        isEnabled: Bool,
        selectedModelID: MLModelID?,
        phase: MLSmartSearchPhase,
        installedModelBytes: Int64,
        hasActivatedModel: Bool = false,
        isStartPending: Bool = false,
        startIntent: UInt64 = 0,
        availableModels: [MLModelCatalogEntry],
        isSearchAvailable: Bool,
        indexingState: MLSmartSearchIndexingState = .idle
    ) {
        self.isSupported = isSupported
        self.isEnabled = isEnabled
        self.selectedModelID = selectedModelID
        self.phase = phase
        self.installedModelBytes = installedModelBytes
        self.hasActivatedModel = hasActivatedModel
        self.isStartPending = isStartPending
        self.startIntent = startIntent
        self.availableModels = availableModels
        self.isSearchAvailable = isSearchAvailable
        self.indexingState = indexingState
    }

    public static let disabled = MLSmartSearchSnapshot(
        isEnabled: false,
        selectedModelID: nil,
        phase: .disabled,
        installedModelBytes: 0,
        availableModels: [],
        isSearchAvailable: false,
        indexingState: .idle
    )

    /// The person may choose a model now: whenever no model work runs, and while the first model downloads,
    /// which the choice stops.
    public var allowsModelChoice: Bool {
        guard isEnabled else { return false }
        if case .downloading = phase, !hasActivatedModel { return true }
        return !phase.isBusy
    }

    /// Semantic coverage is independent of native OCR/document retries.
    public var isVisualIndexComplete: Bool {
        guard isEnabled, selectedModelID != nil else { return false }
        switch phase {
        case .ready(let coverage), .waiting(let coverage): return coverage.isComplete
        case .indexing(let progress):
            return progress.indexed + progress.alreadyIndexed + progress.permanentFailure >= progress.totalAssets
        default: return false
        }
    }

    /// Automatic suggestions yield to initial indexing and active retry quanta, not an idle retry timer.
    /// Hosts additionally supply library/thumbnail readiness; the shared resource permit remains authoritative.
    public var permitsAutomaticSuggestionGeneration: Bool {
        guard isEnabled else { return true }
        guard selectedModelID == nil || isVisualIndexComplete else { return false }
        switch indexingState {
        case .ready(let progress): return progress.isComplete
        case .waiting(let progress):
            return progress.totalWorkUnits > 0
                && progress.settledWorkUnits + progress.deferredWorkUnits == progress.totalWorkUnits
        default: return false
        }
    }

    /// Local metadata can remain useful when a model needs user action or an index has failed.
    /// This never authorizes inference, geocoding, or persistence of a partial collection.
    public var permitsAutomaticSuggestionMetadata: Bool {
        guard isEnabled else { return true }
        switch indexingState {
        case .indexing: return false
        case .waiting(let progress):
            guard progress.settledWorkUnits + progress.deferredWorkUnits == progress.totalWorkUnits else {
                return false
            }
        case .ready(let progress):
            guard progress.isComplete else { return false }
        case .idle, .failed: break
        }
        switch phase {
        case .selectingModel, .notInstalled, .downloading, .failed: return true
        case .disabled, .ready, .waiting, .indexing:
            if case .failed = indexingState { return true }
            return false
        default: return false
        }
    }
}

/// Journal marker for multi-step operations that must complete across a crash.
public enum MLSmartSearchPendingOperation: Sendable, Equatable, Codable {
    /// Purge started: every restart finishes the purge before anything else runs.
    case purge
    /// Model switch committed: the previous epoch's vectors and artifacts must be gone before
    /// the new model activates.
    case switchModel(from: MLModelID?, to: MLModelID)
}

/// Minimal persisted lifecycle state (crash recovery only; everything else is derived).
public struct MLSmartSearchPersistentState: Sendable, Equatable, Codable {
    public var isEnabled: Bool
    public var selectedModelID: MLModelID?
    /// Revision of the activated installation, so relaunches load exactly what was verified.
    public var activatedRevision: String?
    /// Embedding epoch produced by the activated installation. A pending cleanup retains it
    /// until its journal commits.
    public var activatedDescriptor: MLModelDescriptor?
    public var pendingOperation: MLSmartSearchPendingOperation?

    public init(
        isEnabled: Bool = false,
        selectedModelID: MLModelID? = nil,
        activatedRevision: String? = nil,
        activatedDescriptor: MLModelDescriptor? = nil,
        pendingOperation: MLSmartSearchPendingOperation? = nil
    ) {
        self.isEnabled = isEnabled
        self.selectedModelID = selectedModelID
        self.activatedRevision = activatedRevision
        self.activatedDescriptor = activatedDescriptor
        self.pendingOperation = pendingOperation
    }
}

/// Persistence seam for `MLSmartSearchPersistentState`.
///
/// State writes are atomic and every read/write failure is surfaced to the lifecycle.
public protocol MLSmartSearchStateStore: Sendable {
    func load() throws -> MLSmartSearchPersistentState?
    func save(_ state: MLSmartSearchPersistentState) throws
    /// Remove the persisted state entirely (final purge step).
    func clear()
}

/// Atomic JSON-file state store inside the Smart Search root (so purge provably removes it).
public struct FileMLSmartSearchStateStore: MLSmartSearchStateStore {
    private let fileURL: URL

    public init(layout: MLModelInstallLayout) {
        self.fileURL = layout.stateFileURL
    }

    public func load() throws -> MLSmartSearchPersistentState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(MLSmartSearchPersistentState.self, from: data)
    }

    public func save(_ state: MLSmartSearchPersistentState) throws {
        let data = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// The Smart Search switch between a tap and the lifecycle's answer. The person's latest intent shows until a
/// snapshot proves that the lifecycle applied it, so an older snapshot can neither flip the switch back nor let it
/// flicker off.
public struct MLSmartSearchStartSwitch: Sendable, Equatable {
    private var override: Bool?
    private var lastIntent: UInt64 = 0

    public init() {}

    /// Records a tap and returns its intent number for the lifecycle.
    public mutating func request(on: Bool) -> UInt64 {
        lastIntent &+= 1
        override = on
        return lastIntent
    }

    public mutating func apply(_ snapshot: MLSmartSearchSnapshot) {
        if snapshot.startIntent >= lastIntent { override = nil }
    }

    /// The lifecycle refused the switch-on outright.
    public mutating func refused(_ intent: UInt64) {
        if intent == lastIntent { override = nil }
    }

    /// Smart Search is on its way: the person switched it on and it is not enabled yet.
    public func isStarting(_ snapshot: MLSmartSearchSnapshot) -> Bool {
        !snapshot.isEnabled && (override ?? snapshot.isStartPending)
    }
}
