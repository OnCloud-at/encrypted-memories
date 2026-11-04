import Foundation

/// The reason and available action of a failed "Keep Only Favorites" attempt.
public struct SeriesFailurePresentation: Equatable, Sendable {
    public let message: String
    public let canRetry: Bool

    public init(error: any Error) {
        if let failure = error as? SeriesDissolutionError {
            message = failure.errorDescription ?? ""
            canRetry = failure != .invalidSelection
        } else {
            message = ""
            canRetry = true
        }
    }
}
