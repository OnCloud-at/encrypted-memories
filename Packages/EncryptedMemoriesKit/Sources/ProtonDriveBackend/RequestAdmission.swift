import Foundation
import PhotosCore

/// Runs one backend operation under the request cause of its feature and the shutdown gate of the signed-in session.
/// Without a gate or a cause the operation runs as it is, which keeps tests free of a bridge.
struct RequestAdmission: Sendable {
    let gate: JoinedShutdownGate?
    let requestCause: ProtonRequestCauseBinding?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let requestCause else { return try await admitted(operation) }
        return try await requestCause.run { try await admitted(operation) }
    }

    private func admitted<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let gate else { return try await operation() }
        return try await gate.withAdmission(operation)
    }
}
