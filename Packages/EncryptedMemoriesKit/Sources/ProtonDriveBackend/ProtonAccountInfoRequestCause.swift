/// Diagnostic labels for the two mobile account refresh callers. This scope changes no request behavior.
public enum ProtonAccountInfoRequestCause: Sendable {
    case foregroundActivation
    case visibleSettings

    public func run<T>(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        let cause: ProtonRequestCause =
            self == .foregroundActivation ? .accountForeground : .accountSettings
        return try await ProtonRequestContext.$cause.withValue(cause) {
            try await operation()
        }
    }
}
