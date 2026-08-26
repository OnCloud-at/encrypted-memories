import Foundation

/// Couples one SDK operation to its matching native cancellation call with the same token.
enum SDKCancellableOperation {
    static func run<Value: Sendable>(
        operation: @Sendable @escaping (UUID) async throws -> Value,
        cancel: @Sendable @escaping (UUID) async -> Void
    ) async throws -> Value {
        let token = UUID()
        let cancellation = SDKCancellationJoin(token: token, cancel: cancel)
        let result: Result<Value, any Error>
        do {
            result = .success(
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await operation(token)
                } onCancel: {
                    cancellation.request()
                })
        } catch {
            result = .failure(error)
        }

        // A non-cooperative operation can return while cancellation is already pending. Requesting
        // again is harmless and closes the race with the synchronous cancellation handler.
        if Task.isCancelled {
            cancellation.request()
        }
        await cancellation.join()

        switch result {
        case .success(let value):
            try Task.checkCancellation()
            return value
        case .failure(let error):
            throw error
        }
    }
}

private final class SDKCancellationJoin: @unchecked Sendable {
    private let token: UUID
    private let cancel: @Sendable (UUID) async -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(token: UUID, cancel: @escaping @Sendable (UUID) async -> Void) {
        self.token = token
        self.cancel = cancel
    }

    func request() {
        lock.withLock {
            guard task == nil else { return }
            task = Task { [token, cancel] in
                await cancel(token)
            }
        }
    }

    func join() async {
        let pending = lock.withLock { task }
        await pending?.value
    }
}

/// Thread-safe buffer for SDK enumeration callbacks. Callers publish the result only after the
/// native enumeration has completed, so a callback failure cannot expose a partial timeline.
final class SDKEnumerationCollector<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []
    private var firstError: (any Error)?

    func receive(_ result: Result<Element, any Error>) {
        lock.withLock {
            guard firstError == nil else { return }
            switch result {
            case .success(let element):
                elements.append(element)
            case .failure(let error):
                firstError = error
            }
        }
    }

    func collected() throws -> [Element] {
        try lock.withLock {
            if let firstError {
                throw firstError
            }
            return elements
        }
    }
}
