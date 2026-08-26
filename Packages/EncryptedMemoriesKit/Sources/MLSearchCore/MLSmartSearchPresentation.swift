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
                detail = Self.unavailableDetail(progress)
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
                // Native Vision starts independently; selecting a semantic model is optional.
                status = L10n.string("mlsearch.status_preparing_index")
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
                    detail = Self.coverageDetail(coverage)
                    fraction = coverage.accountedFraction
                }
            case .ready(let coverage):
                indexed = coverage.indexed
                total = coverage.total
                status = Self.readyStatus
                ready = true
                if total > 0 {
                    detail = Self.readyCoverageDetail(coverage)
                }
            case .switchingModel:
                status = L10n.string("mlsearch.status_switching")
            case .deleting:
                status = L10n.string("mlsearch.status_deleting")
            case .failed(let failure):
                status = Self.failureStatus(failure)
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

    private static func coverageDetail(_ coverage: MLIndexCoverage) -> String {
        if coverage.permanentlyUnindexable > 0 {
            return L10n.string(
                "mlsearch.indexed_with_failures \(coverage.indexed) \(coverage.total) \(coverage.permanentlyUnindexable)"
            )
        }
        return L10n.string("mlsearch.indexed_count \(coverage.indexed) \(coverage.total)")
    }

    private static func readyCoverageDetail(_ coverage: MLIndexCoverage) -> String {
        if coverage.permanentlyUnindexable > 0 {
            return L10n.string(
                "mlsearch.ready_with_unavailable \(coverage.indexed) \(coverage.permanentlyUnindexable)"
            )
        }
        return L10n.string("mlsearch.ready_count \(coverage.indexed)")
    }

    private static func aggregateDetail(_ progress: MLSmartSearchAggregateProgress) -> String? {
        guard let fraction = progress.fraction else { return nil }
        return L10n.string("mlsearch.work_progress_percent \(Int((fraction * 100).rounded()))")
    }

    private static func unavailableDetail(_ progress: MLSmartSearchAggregateProgress) -> String? {
        guard progress.permanentlyUnavailableAssets > 0 else { return nil }
        let count = L10n.string("mlsearch.work_unavailable \(progress.permanentlyUnavailableAssets)")
        let reasons = progress.unavailableAssetReasons.keys.sorted { $0.rawValue < $1.rawValue }.map {
            switch $0 {
            case .sourceCorrupt: L10n.string("mlsearch.failure_source_corrupt")
            case .invalidArtifactContract: L10n.string("mlsearch.failure_invalid_artifact")
            case .invalidExecutorResult: L10n.string("mlsearch.failure_invalid_result")
            case .analysisFailed: L10n.string("mlsearch.failure_analysis")
            case .retryLimitReached: L10n.string("mlsearch.failure_retry_limit")
            }
        }
        return reasons.isEmpty ? count : "\(count) · \(reasons.joined(separator: ", "))"
    }

    fileprivate static func failureStatus(_ failure: MLSmartSearchFailure) -> String {
        switch failure.kind {
        case .catalog: L10n.string("mlsearch.status_failed_catalog")
        case .download: L10n.string("mlsearch.status_failed_download")
        case .verification: L10n.string("mlsearch.status_failed_verification")
        case .installation: L10n.string("mlsearch.status_failed_installation")
        case .modelLoad: L10n.string("mlsearch.status_failed_model")
        case .storage: L10n.string("mlsearch.status_failed_storage")
        }
    }
}

/// Optional semantic-model status. Native analysis remains usable when this reports a model error.
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
