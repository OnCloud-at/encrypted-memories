/// Model-calibrated relevance boundary for semantic search results.
///
/// Approximate-nearest-neighbour ranking always has a "nearest" image, even when nothing is
/// relevant. The UI must therefore never receive an arbitrary top-K tail. Each trusted model
/// catalog entry owns its measured score boundary, while this shared Core policy applies it once
/// for macOS, iOS and iPadOS.
public struct MLSemanticRelevancePolicy: Sendable, Equatable {
    /// The strongest result must reach this score or the query has no semantic matches.
    public let minimumBestScore: Float
    /// Every returned result must reach this absolute score.
    public let minimumResultScore: Float
    /// Every returned result must also remain within this fraction of the best score.
    public let relativeScoreFloor: Float?

    public init(
        minimumBestScore: Float,
        minimumResultScore: Float,
        relativeScoreFloor: Float?
    ) {
        self.minimumBestScore = minimumBestScore
        self.minimumResultScore = minimumResultScore
        self.relativeScoreFloor = relativeScoreFloor
    }

    /// Used by tests and developer-provided models that have not completed score calibration.
    /// Production catalog entries must declare an explicit measured policy.
    public static let unfiltered = MLSemanticRelevancePolicy(
        minimumBestScore: -.infinity,
        minimumResultScore: -.infinity,
        relativeScoreFloor: nil
    )

    public func relevantResults(from rankedResults: [MLSearchResult]) -> [MLSearchResult] {
        guard let best = rankedResults.first, best.score >= minimumBestScore else { return [] }
        let relativeFloor = relativeScoreFloor.map { best.score * $0 } ?? -.infinity
        let cutoff = max(minimumResultScore, relativeFloor)
        return Array(rankedResults.prefix { $0.score >= cutoff })
    }
}
