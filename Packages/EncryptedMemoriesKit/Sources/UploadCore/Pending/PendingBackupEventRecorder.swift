import Foundation
import PhotosCore

/// A runner event after the recorder made it durable.
public enum PendingRuntimeEvent: Sendable, Equatable {
    case evidence(PendingSourceKey, UploadBackupRevision)
    case handoff(PendingHandoff, PendingHandoffOutcome)
    case progress(PendingSourceKey, UploadBackupRevision, step: Int?)
}

/// The runner's event sink. It writes durable facts to the pending store synchronously, then forwards every
/// event to the coordinator without blocking the runner.
public final class PendingBackupEventRecorder: BackupItemEventSink, @unchecked Sendable {
    public let events: AsyncStream<PendingRuntimeEvent>
    private let continuation: AsyncStream<PendingRuntimeEvent>.Continuation
    private let store: PendingBackupManifestStore
    private let now: @Sendable () -> Date

    public init(store: PendingBackupManifestStore, now: @Sendable @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: PendingRuntimeEvent.self, bufferingPolicy: .unbounded)
    }

    deinit { continuation.finish() }

    public func finish() { continuation.finish() }

    public func recordUploadEvidence(source: UploadSourceIdentity, revision: UploadBackupRevision) {
        let key = PendingSourceKey(source)
        guard store.recordUploadEvidence(key, revision: revision, at: now()) else { return }
        continuation.yield(.evidence(key, revision))
    }

    @discardableResult
    public func recordHandoff(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        remote: PhotoUID,
        kind: PendingHandoffKind
    ) -> PendingHandoffOutcome {
        let handoff = PendingHandoff(
            key: PendingSourceKey(source),
            revision: revision,
            remote: remote,
            kind: kind,
            createdAt: now()
        )
        let outcome = store.recordHandoff(handoff)
        if outcome != .failed { continuation.yield(.handoff(handoff, outcome)) }
        return outcome
    }

    public func isExcluded(source: UploadSourceIdentity) -> Bool? {
        store.excludedIdentifiers(kind: source.kind, among: [source.identifier]).map { $0.contains(source.identifier) }
    }

    public func reportProgress(source: UploadSourceIdentity, revision: UploadBackupRevision, step: Int?) {
        continuation.yield(.progress(PendingSourceKey(source), revision, step: step))
    }
}
