import Foundation
import PhotosCore

/// UI-ready projection of an `MLSmartSearchSnapshot`.
///
/// One localized wording implementation for every platform (strings resolve against the
/// package catalog via `L10n`), mirroring how `BackupStatus` keeps macOS and iOS wording
/// identical. Views render these fields verbatim and never derive their own status copy.
public struct MLSmartSearchPresentation: Sendable, Equatable {
    public let statusText: String
    public let detailText: String?
    /// Determinate progress in `[0, 1]`, or `nil` when no progress bar should show.
    public let progressFraction: Double?
    public let indexedCount: Int
    public let totalCount: Int
    public let modelSizeText: String?
    /// Media that could not be analyzed. They stay in the library; settings keep this behind an info button so a
    /// finished index still reads as ready.
    public let unavailableNote: String?
    public let canRetry: Bool
    public let isBusy: Bool
    /// Lets the shared settings view use completed-state iconography without re-deriving policy.
    public let presentsAsReady: Bool

    public init(snapshot: MLSmartSearchSnapshot) {
        var detail: String?
        var fraction: Double?
        var indexed = 0
        var total = 0
        var retry = false
        var ready = false
        var unavailable: String?

        let aggregateStatus: String?
        if snapshot.isEnabled {
            switch snapshot.indexingState {
            case .idle:
                aggregateStatus = nil
            case .indexing(let progress):
                aggregateStatus = L10n.string("mlsearch.status_indexing")
                fraction = progress.fraction
                indexed = progress.settledWorkUnits
                total = progress.totalWorkUnits
                detail = Self.aggregateDetail(progress)
            case .waiting(let progress):
                aggregateStatus = L10n.string("mlsearch.status_waiting")
                fraction = progress.fraction
                indexed = progress.settledWorkUnits
                total = progress.totalWorkUnits
                detail = Self.aggregateDetail(progress)
            case .ready(let progress):
                aggregateStatus = Self.readyStatus
                indexed = progress.settledWorkUnits
                total = progress.totalWorkUnits
                ready = true
                unavailable = Self.unavailableNote(
                    count: progress.permanentlyUnavailableAssets,
                    reasons: Array(progress.unavailableAssetReasons.keys)
                )
            case .failed(let failure):
                aggregateStatus = Self.failureStatus(failure)
                retry = failure.isRetryable
            }
        } else {
            aggregateStatus = nil
        }

        let status: String
        if let aggregateStatus {
            status = aggregateStatus
        } else {
            switch snapshot.phase {
            case .disabled:
                status = L10n.string("mlsearch.status_disabled")
            case .loadingCatalog:
                status = L10n.string("mlsearch.status_loading_catalog")
            case .selectingModel:
                // Native Vision keeps indexing, but Smart Search needs a model to be complete.
                status = L10n.string("mlsearch.status_select_model")
            case .notInstalled(let downloadable):
                status =
                    downloadable
                    ? L10n.string("mlsearch.status_not_installed")
                    : L10n.string("mlsearch.status_not_downloadable")
            case .downloading(let progress):
                status = L10n.string("mlsearch.status_downloading")
                fraction = progress.fraction
                if let totalBytes = progress.totalBytes, totalBytes > 0 {
                    let received = L10n.fileSize(progress.bytesReceived)
                    let total = L10n.fileSize(totalBytes)
                    detail = L10n.string("mlsearch.downloaded_bytes \(received) \(total)")
                }
            case .verifying:
                status = L10n.string("mlsearch.status_verifying")
            case .installing:
                status = L10n.string("mlsearch.status_installing")
            case .preparingModel:
                status = L10n.string("mlsearch.status_preparing")
            case .indexing(let progress):
                status = L10n.string("mlsearch.status_indexing")
                fraction = progress.totalAssets > 0 ? progress.fraction : nil
                indexed = progress.indexed + progress.alreadyIndexed
                total = progress.totalAssets
                detail = L10n.string("mlsearch.indexed_count \(indexed) \(total)")
            case .waiting(let coverage):
                indexed = coverage.indexed
                total = coverage.total
                if coverage.isSearchReadyWithMinorPendingWork {
                    status = Self.readyStatus
                    detail = L10n.string("mlsearch.ready_with_pending \(coverage.pending)")
                    ready = true
                } else {
                    status = L10n.string("mlsearch.status_waiting")
                }
                if total > 0, detail == nil {
                    detail = L10n.string("mlsearch.indexed_count \(coverage.indexed) \(coverage.total)")
                    fraction = coverage.accountedFraction
                }
                unavailable = Self.unavailableNote(count: coverage.permanentlyUnindexable, reasons: [])
            case .ready(let coverage):
                indexed = coverage.indexed
                total = coverage.total
                status = Self.readyStatus
                ready = true
                if total > 0 {
                    detail = L10n.string("mlsearch.ready_count \(coverage.indexed)")
                }
                unavailable = Self.unavailableNote(count: coverage.permanentlyUnindexable, reasons: [])
            case .switchingModel:
                status = L10n.string("mlsearch.status_switching")
            case .deleting:
                status = L10n.string("mlsearch.status_deleting")
            case .failed(let failure):
                status = Self.failureStatus(failure)
                detail = Self.failureDetail(failure)
                retry = failure.isRetryable
            }
        }

        self.statusText = status
        self.detailText = detail
        self.progressFraction = fraction
        self.indexedCount = indexed
        self.totalCount = total
        let selectedModel = snapshot.availableModels.first { $0.id == snapshot.selectedModelID }
        let modelBytes =
            snapshot.installedModelBytes > 0
            ? snapshot.installedModelBytes
            : selectedModel?.downloadPlan?.totalByteCount ?? 0
        self.modelSizeText =
            modelBytes > 0
            ? L10n.fileSize(modelBytes)
            : nil
        self.unavailableNote = unavailable
        self.canRetry = retry
        self.isBusy =
            snapshot.phase.isBusy
            || {
                if case .indexing = snapshot.indexingState { return true }
                return false
            }()
        self.presentsAsReady = ready
    }

    /// One localized product name reused by settings, search scopes and status copy.
    public static var productName: String {
        L10n.string("mlsearch.product_name")
    }

    /// Shared privacy statement shown in every Smart Search settings surface.
    public static var privacyStatement: String {
        L10n.string("mlsearch.privacy_note \(productName)")
    }

    /// Warning line for developer-only models.
    public static var developerModelNote: String {
        L10n.string("mlsearch.developer_model_note")
    }

    private static var readyStatus: String {
        L10n.string("mlsearch.status_ready \(productName)")
    }

    private static func aggregateDetail(_ progress: MLSmartSearchAggregateProgress) -> String? {
        guard let fraction = progress.fraction else { return nil }
        return L10n.string("mlsearch.work_progress_percent \(Int((fraction * 100).rounded()))")
    }

    private static func unavailableNote(count: Int, reasons: [MLPipelineFailureReason]) -> String? {
        guard count > 0 else { return nil }
        let note = L10n.string("mlsearch.unavailable_note \(count)")
        let names = reasons.sorted { $0.rawValue < $1.rawValue }.map {
            switch $0 {
            case .sourceCorrupt: L10n.string("mlsearch.failure_source_corrupt")
            case .invalidArtifactContract: L10n.string("mlsearch.failure_invalid_artifact")
            case .invalidExecutorResult: L10n.string("mlsearch.failure_invalid_result")
            case .analysisFailed: L10n.string("mlsearch.failure_analysis")
            case .retryLimitReached: L10n.string("mlsearch.failure_retry_limit")
            }
        }
        guard !names.isEmpty else { return note }
        return note + "\n\n" + L10n.string("mlsearch.unavailable_reasons \(names.joined(separator: ", "))")
    }

    fileprivate static func failureStatus(_ failure: MLSmartSearchFailure) -> String {
        switch failure.kind {
        case .catalog: L10n.string("mlsearch.status_failed_catalog")
        case .download: L10n.string("mlsearch.status_failed_download")
        case .verification: L10n.string("mlsearch.status_failed_verification")
        case .installation: L10n.string("mlsearch.status_failed_installation")
        case .modelLoad: L10n.string("mlsearch.status_failed_model")
        case .storage: L10n.string("mlsearch.status_failed_storage")
        case .insufficientStorage: L10n.string("mlsearch.status_failed_space")
        }
    }

    fileprivate static func failureDetail(_ failure: MLSmartSearchFailure) -> String? {
        guard failure.kind == .insufficientStorage, let required = failure.requiredBytes, required > 0 else {
            return nil
        }
        return L10n.string("mlsearch.space_required \(L10n.fileSize(required))")
    }
}

/// Model download and activation status. Native analysis remains usable when this reports a model error.
public struct MLSmartSearchModelPresentation: Sendable, Equatable {
    public let statusText: String?
    public let detailText: String?
    public let progressFraction: Double?
    public let canRetry: Bool
    public let isBusy: Bool

    public init(snapshot: MLSmartSearchSnapshot) {
        var status: String?
        var detail: String?
        var progressFraction: Double?
        var canRetry = false

        switch snapshot.phase {
        case .loadingCatalog:
            status = L10n.string("mlsearch.status_loading_catalog")
        case .notInstalled(let downloadable):
            status =
                downloadable
                ? L10n.string("mlsearch.status_not_installed")
                : L10n.string("mlsearch.status_not_downloadable")
        case .downloading(let progress):
            status = L10n.string("mlsearch.status_downloading")
            progressFraction = progress.fraction
            if let totalBytes = progress.totalBytes, totalBytes > 0 {
                let received = L10n.fileSize(progress.bytesReceived)
                let total = L10n.fileSize(totalBytes)
                detail = L10n.string("mlsearch.downloaded_bytes \(received) \(total)")
            }
        case .verifying:
            status = L10n.string("mlsearch.status_verifying")
        case .installing:
            status = L10n.string("mlsearch.status_installing")
        case .preparingModel:
            status = L10n.string("mlsearch.status_preparing")
        case .switchingModel:
            status = L10n.string("mlsearch.status_switching")
        case .failed(let failure) where failure.kind != .storage:
            status = MLSmartSearchPresentation.failureStatus(failure)
            detail = MLSmartSearchPresentation.failureDetail(failure)
            canRetry = failure.isRetryable
        case .disabled, .selectingModel, .indexing, .waiting, .ready, .deleting, .failed:
            break
        }

        self.statusText = status
        self.detailText = detail
        self.progressFraction = progressFraction
        self.canRetry = canRetry
        self.isBusy = snapshot.phase.isBusy
    }
}
