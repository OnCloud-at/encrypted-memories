@available(macOS 15.0, iOS 18.0, *)
extension AppleVisionPipelineExecutor {
    enum RoutingDecision: Equatable {
        case run
        case skip
        case retry
    }

    static func routingDecision(
        for result: ArtifactAnalysisResult?
    ) -> RoutingDecision {
        guard let result else { return .run }
        switch result {
        case .completed:
            return .run
        case .completedEmpty, .unsupported:
            return .skip
        case .retryableFailure, .permanentFailure:
            return .retry
        }
    }
}
