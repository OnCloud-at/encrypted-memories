import Foundation

/// Classifies Proton failures in one place, so every call site reads the same rule. Further call sites join this type
/// instead of adding another classifier.
enum ProtonFailureClassifier {
    /// What an HTTP status of a Proton answer proves about a repeat of the same request.
    enum HTTPStatus: Equatable, Sendable {
        /// A later attempt can get another answer: 408, 423, 425, 429 and 5xx.
        case temporary
        /// Proton refused the request itself, so a repeat gets the same answer: every 4xx other than 401, 403, 408,
        /// 409, 423, 425 and 429. This list is an assumption from HTTP semantics: 401 and 403 depend on the session
        /// and its rights, and 409 on state that can change. No Proton server documentation confirms it.
        case serviceRejection
        /// Any other code proves neither.
        case unproven
    }

    static func httpStatus(_ code: Int) -> HTTPStatus {
        switch code {
        case 408, 423, 425, 429, 500...599: .temporary
        case 401, 403, 409: .unproven
        case 400...499: .serviceRejection
        default: .unproven
        }
    }
}
