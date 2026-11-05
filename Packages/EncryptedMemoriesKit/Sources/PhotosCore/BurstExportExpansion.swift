import Foundation

/// Decides, once and for every host, which photos an export request carries after expanding
/// Proton burst/series selections.
///
/// The hosts pass their backend's burst-group lookup as a closure and present the returned
/// result; they never interpret burst semantics themselves. A burst candidate whose group read
/// throws is an export failure, not a silent single-photo export.
public enum BurstExportExpansion {
    /// The expansion outcome of one export request.
    public enum Result: Equatable, Sendable {
        /// The deduplicated items to export, and whether a single burst series was expanded
        /// (which names the ZIP after that series instead of the generic container).
        case success(items: [PhotoItem], expandedSingleSeries: Bool)
        /// At least one burst candidate's group read threw; nothing must be exported.
        case burstReadFailed(failedSources: [PhotoItem])
        /// The caller's task was cancelled; nothing was exported and no failure happened.
        /// The host must not present a failure alert for a cancellation it initiated.
        case cancelled
    }

    /// Expands the source items of an export request.
    ///
    /// `preferredSeriesNameSource` is the single tapped item a viewer export names the archive
    /// after. A multi-item selection that already contains the whole known series of that item
    /// takes the fast path and performs no backend reads.
    public static func expand(
        sourceItems: [PhotoItem],
        preferredSeriesNameSource: PhotoItem?,
        burstGroupReader: @escaping @Sendable (PhotoUID) async throws -> [PhotoItem]
    ) async -> Result {
        var expanded: [PhotoItem] = []
        var seen = Set<PhotoUID>()
        var expandedSingleSeries = false
        var failedSources: [PhotoItem] = []

        func appendUnique(_ item: PhotoItem) {
            guard seen.insert(item.uid).inserted else { return }
            expanded.append(item)
        }

        let memberIDSet = Set(
            (preferredSeriesNameSource?.burstMemberIDs ?? []).map {
                PhotoUID(volumeID: preferredSeriesNameSource?.uid.volumeID ?? "", nodeID: $0)
            })
        let sourceUIDSet = Set(sourceItems.map(\.uid))
        let alreadyExpandedPreferredSeries =
            sourceItems.count > 1
            && preferredSeriesNameSource?.isBurstCandidate == true
            && !memberIDSet.isEmpty
            && sourceUIDSet.isSubset(of: memberIDSet)

        if alreadyExpandedPreferredSeries {
            sourceItems.forEach(appendUnique)
            expandedSingleSeries = true
        } else {
            for item in sourceItems {
                guard item.isBurstCandidate else {
                    appendUnique(item)
                    continue
                }
                let group: [PhotoItem]
                do {
                    group = try await burstGroupReader(item.uid)
                } catch {
                    if Self.isCancellation(error) {
                        return .cancelled
                    }
                    failedSources.append(item)
                    continue
                }
                if group.count > 1 {
                    group.forEach(appendUnique)
                    expandedSingleSeries = true
                } else {
                    appendUnique(item)
                }
            }
        }

        if !failedSources.isEmpty {
            return .burstReadFailed(failedSources: failedSources)
        }
        return .success(items: expanded, expandedSingleSeries: expandedSingleSeries)
    }

    /// A cancelled read reaches this function as Swift's `CancellationError`, as the
    /// raw `URLError(.cancelled)` the URLSession transport rethrows, or as any
    /// error thrown while the surrounding task is already cancelled. None of
    /// these shapes is a read failure.
    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || Task.isCancelled
    }
}
