import Foundation
import PhotosCore

/// Retires account-owned merges and rejects results from an earlier account lifetime.
@MainActor
public final class ExactDuplicatesAccountLifetime {
    public struct Token: Equatable, Sendable {
        fileprivate let id: UUID
    }

    private var token = Token(id: UUID())
    private weak var model: ExactDuplicatesModel?

    public init() {}

    public func isCurrent(_ token: Token) -> Bool { self.token == token }

    /// Captures the account token before any merge work starts. A callback that suspends checks it again before
    /// publishing through `isCurrent(_:)`.
    public func replace(
        with finder: (any ExactDuplicateMerging)?,
        didTrash: @escaping @MainActor ([PhotoUID], Token) async -> Void = { _, _ in }
    ) -> ExactDuplicatesModel? {
        retire()
        guard let finder else { return nil }
        let token = self.token
        let next = ExactDuplicatesModel(finder: finder) { [weak self] trashed in
            guard let self, self.isCurrent(token) else { return }
            await didTrash(trashed, token)
        }
        model = next
        return next
    }

    /// Invalidates callbacks before waking a paused run. A running backend batch remains joined by its merge task.
    public func retire() {
        token = Token(id: UUID())
        model?.stopMergeAll()
        model = nil
    }
}
