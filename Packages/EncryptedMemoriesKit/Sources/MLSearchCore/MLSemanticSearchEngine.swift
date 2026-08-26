import Foundation
import PhotosCore

public protocol MLTextQueryEncoder: Sendable {
    func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32>
}

public enum MLSemanticSearchError: Error, Equatable {
    case emptyQuery
    case invalidQueryEmbedding
    case queryDimensionMismatch(expected: Int, actual: Int)
}

/// Shared semantic query path for every host platform.
///
/// The engine owns query normalization, bounded index streaming and deterministic ranking. CoreML
/// model execution and Accelerate arithmetic remain injected adapters, so iOS, iPadOS and macOS
/// cannot diverge in search semantics.
public actor MLSemanticSearchEngine {
    private let store: any MLIndexStore
    private let encoder: any MLTextQueryEncoder
    private let scorer: any MLVectorScorer
    private let relevancePolicy: MLSemanticRelevancePolicy
    /// A 512-dimensional Float32 query block uses about 4 MiB at this row limit.
    /// The bound applies to every library size; top-k memory still follows the requested limit.
    public static let defaultQueryBlockRowLimit = 2_048
    private let queryBlockRowLimit: Int

    public init(
        store: any MLIndexStore,
        encoder: any MLTextQueryEncoder,
        scorer: any MLVectorScorer,
        relevancePolicy: MLSemanticRelevancePolicy = .unfiltered,
        queryBlockRowLimit: Int = MLSemanticSearchEngine.defaultQueryBlockRowLimit
    ) {
        self.store = store
        self.encoder = encoder
        self.scorer = scorer
        self.relevancePolicy = relevancePolicy
        self.queryBlockRowLimit = max(1, queryBlockRowLimit)
    }

    public func search(_ query: MLSearchQuery) async throws -> MLSearchResults {
        let text = query.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MLSemanticSearchError.emptyQuery }

        let raw = try await encoder.encode(text: text, descriptor: query.descriptor)
        guard raw.count == query.descriptor.embeddingDimension else {
            throw MLSemanticSearchError.queryDimensionMismatch(
                expected: query.descriptor.embeddingDimension,
                actual: raw.count
            )
        }
        guard let normalized = MLVectorNormalization.normalized(raw) else {
            throw MLSemanticSearchError.invalidQueryEmbedding
        }

        let startedAt = ContinuousClock.now
        var rankedResults: [MLSearchResult] = []
        if query.limit > 0 {
            store.forEachVectorBlock(
                for: query.descriptor,
                maximumRows: queryBlockRowLimit
            ) { block in
                let blockResults = scorer.rank(
                    block: block,
                    query: normalized,
                    limit: query.limit,
                    queryText: text
                ).results
                rankedResults = Self.mergeTopResults(
                    rankedResults,
                    blockResults,
                    limit: query.limit
                )
            }
        }
        try Task.checkCancellation()
        let duration = ContinuousClock.now - startedAt
        return MLSearchResults(
            descriptor: query.descriptor,
            queryText: text,
            results: relevancePolicy.relevantResults(from: rankedResults),
            durationMs: Double(duration.components.seconds) * 1_000
                + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        )
    }

    public func coverage(for descriptor: MLModelDescriptor, allAssets: [PhotoUID]) -> MLIndexCoverage {
        store.coverage(for: descriptor, allAssets: allAssets)
    }

    public func permanentlyUnavailableAssetUIDs(
        for descriptor: MLModelDescriptor,
        allAssets: [PhotoUID]
    ) -> Set<PhotoUID> {
        let assets = Array(Set(allAssets))
        let indexed = store.indexedUIDs(for: descriptor, from: assets)
        return Set(
            store.failureRecords(for: descriptor, from: assets).values.compactMap { failure in
                failure.kind == .permanent && !indexed.contains(failure.uid) ? failure.uid : nil
            })
    }

    public func purgeCachedBlocks() {
        // Query vectors are streamed per search. Keep this API for lifecycle memory-pressure
        // callers, which also release the active inference model through the adapter.
    }

    private static func mergeTopResults(
        _ existing: [MLSearchResult],
        _ incoming: [MLSearchResult],
        limit: Int
    ) -> [MLSearchResult] {
        guard !incoming.isEmpty else { return existing }
        var merged: [MLSearchResult] = []
        merged.reserveCapacity(min(limit, existing.count + incoming.count))
        var existingIndex = 0
        var incomingIndex = 0

        while merged.count < limit,
            existingIndex < existing.count || incomingIndex < incoming.count
        {
            if incomingIndex == incoming.count {
                merged.append(existing[existingIndex])
                existingIndex += 1
            } else if existingIndex == existing.count {
                merged.append(incoming[incomingIndex])
                incomingIndex += 1
            } else if existing[existingIndex].score >= incoming[incomingIndex].score {
                // Blocks arrive in store order, so retaining the existing row first preserves
                // the scorer's deterministic ascending-row tie break across block boundaries.
                merged.append(existing[existingIndex])
                existingIndex += 1
            } else {
                merged.append(incoming[incomingIndex])
                incomingIndex += 1
            }
        }
        return merged
    }
}
