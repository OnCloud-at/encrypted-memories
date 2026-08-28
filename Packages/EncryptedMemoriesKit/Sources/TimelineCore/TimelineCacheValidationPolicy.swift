import PhotosCore

/// Result of comparing a persisted timeline's paired server revision with the current cheap event token.
public enum TimelineCacheValidation: Equatable, Sendable {
    /// The cached inventory is still the server's current inventory and may be presented without a full load.
    case validated(token: String)
    /// The cache is unproven or stale. `monitorBaseline` seeds change monitoring so a mutation that happened
    /// before its first poll is not silently consumed as a new baseline.
    case refreshRequired(monitorBaseline: String?)
    /// The cached scope no longer exists or is no longer accessible. Retrying through the same repository is
    /// invalid; the host must retire and rebuild its account-scoped backend.
    case terminalFailure

    public var monitorBaseline: String? {
        switch self {
        case .validated(let token): token
        case .refreshRequired(let monitorBaseline): monitorBaseline
        case .terminalFailure: nil
        }
    }
}

/// One cross-platform decision point for fast, flicker-free warm launches.
///
/// A disk cache becomes authoritative only when it was saved with a stable Proton event token and the cheap
/// current token still matches. Missing tokens, unsupported providers, and probe failures all fail closed to a
/// normal authoritative refresh; no platform shell invents a timeout or its own freshness heuristic.
public enum TimelineCacheValidationPolicy {
    public static func validate(
        snapshot: CachedTimelineSnapshot,
        repository: any PhotosRepository
    ) async -> TimelineCacheValidation {
        guard let provider = repository as? any LibraryChangeTokenProvider else {
            return .refreshRequired(monitorBaseline: snapshot.validationToken)
        }
        do {
            let currentToken = try await provider.launchValidationToken(for: snapshot)
            guard currentToken == snapshot.validationToken else {
                return .refreshRequired(monitorBaseline: currentToken)
            }
            return .validated(token: currentToken)
        } catch is any LibraryChangeTerminalError {
            return .terminalFailure
        } catch {
            return .refreshRequired(monitorBaseline: snapshot.validationToken)
        }
    }
}

public struct TimelineCacheValidationTerminalError: LibraryChangeTerminalError {
    public init() {}
}
