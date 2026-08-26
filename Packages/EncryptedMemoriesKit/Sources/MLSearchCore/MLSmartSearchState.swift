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
    }

    public let kind: Kind
    public let isRetryable: Bool
    /// Diagnostic detail for logs; UI copy comes from the presentation layer per `kind`.
    public let debugDescription: String

    public init(kind: Kind, isRetryable: Bool, debugDescription: String) {
        self.kind = kind
        self.isRetryable = isRetryable
        self.debugDescription = debugDescription
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
    public let permanentlyUnavailableAssets: Int
    public let unavailableAssetReasons: [MLPipelineFailureReason: Int]

    public init(
        totalWorkUnits: Int,
        settledWorkUnits: Int,
        permanentlyUnavailableAssets: Int,
        unavailableAssetReasons: [MLPipelineFailureReason: Int] = [:]
    ) {
        self.totalWorkUnits = max(0, totalWorkUnits)
        self.settledWorkUnits = min(max(0, settledWorkUnits), max(0, totalWorkUnits))
        self.permanentlyUnavailableAssets = max(0, permanentlyUnavailableAssets)
        self.unavailableAssetReasons = unavailableAssetReasons.filter { $0.value > 0 }
    }

    public var pendingWorkUnits: Int { max(0, totalWorkUnits - settledWorkUnits) }
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
    public let isEnabled: Bool
    /// Optional semantic image search. Native text, document and barcode analysis remains
    /// controlled by `isEnabled` and does not depend on this setting.
    public let isVisualSearchEnabled: Bool
    public let selectedModelID: MLModelID?
    public let phase: MLSmartSearchPhase
    /// Installed size of the active model in bytes (0 when nothing is installed).
    public let installedModelBytes: Int64
    /// Selectable catalog entries for this environment.
    public let availableModels: [MLModelCatalogEntry]
    /// `true` once any enabled backend has searchable coverage.
    public let isSearchAvailable: Bool
    /// One Core-owned status for all enabled indexing pipelines.
    public let indexingState: MLSmartSearchIndexingState

    public init(
        isEnabled: Bool,
        isVisualSearchEnabled: Bool,
        selectedModelID: MLModelID?,
        phase: MLSmartSearchPhase,
        installedModelBytes: Int64,
        availableModels: [MLModelCatalogEntry],
        isSearchAvailable: Bool,
        indexingState: MLSmartSearchIndexingState = .idle
    ) {
        self.isEnabled = isEnabled
        self.isVisualSearchEnabled = isVisualSearchEnabled
        self.selectedModelID = selectedModelID
        self.phase = phase
        self.installedModelBytes = installedModelBytes
        self.availableModels = availableModels
        self.isSearchAvailable = isSearchAvailable
        self.indexingState = indexingState
    }

    public static let disabled = MLSmartSearchSnapshot(
        isEnabled: false,
        isVisualSearchEnabled: false,
        selectedModelID: nil,
        phase: .disabled,
        installedModelBytes: 0,
        availableModels: [],
        isSearchAvailable: false,
        indexingState: .idle
    )
}

/// Journal marker for multi-step operations that must complete across a crash.
public enum MLSmartSearchPendingOperation: Sendable, Equatable, Codable {
    /// Purge started: every restart finishes the purge before anything else runs.
    case purge
    /// Model switch committed: the previous epoch's vectors and artifacts must be gone before
    /// the new model activates.
    case switchModel(from: MLModelID?, to: MLModelID)
    /// Visual search was disabled: its vectors and model artifacts must be removed while
    /// native analysis and its derived store remain available.
    case disableVisualSearch(model: MLModelID?)
}

/// Minimal persisted lifecycle state (crash recovery only; everything else is derived).
public struct MLSmartSearchPersistentState: Sendable, Equatable, Codable {
    public var isEnabled: Bool
    public var isVisualSearchEnabled: Bool
    public var selectedModelID: MLModelID?
    /// Revision of the activated installation, so relaunches load exactly what was verified.
    public var activatedRevision: String?
    /// Embedding epoch produced by the activated installation. A pending cleanup retains it
    /// until its journal commits.
    public var activatedDescriptor: MLModelDescriptor?
    public var pendingOperation: MLSmartSearchPendingOperation?

    public init(
        isEnabled: Bool = false,
        isVisualSearchEnabled: Bool = false,
        selectedModelID: MLModelID? = nil,
        activatedRevision: String? = nil,
        activatedDescriptor: MLModelDescriptor? = nil,
        pendingOperation: MLSmartSearchPendingOperation? = nil
    ) {
        self.isEnabled = isEnabled
        self.isVisualSearchEnabled = isVisualSearchEnabled
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
