import Foundation

/// Replays only durable local manifest settlement for uploads that already committed remotely.
/// It deliberately has no uploader or normal dedupe-decision dependency, so recovery cannot send
/// bytes, schedule compound siblings, or reinterpret formerly selected album work.
public struct UploadRemoteCommitRecovery: Sendable {
    private static let batchSize = 32

    private let queue: any UploadBackupSyncQueueStore
    private let resolver: any BackupResourceResolving
    private let identityResolver: any UploadIdentityResolving

    public init(
        queue: any UploadBackupSyncQueueStore,
        resolver: any BackupResourceResolving,
        identityResolver: any UploadIdentityResolving
    ) {
        self.queue = queue
        self.resolver = resolver
        self.identityResolver = identityResolver
    }

    /// Returns only after a complete scan found no remaining receipt. Each receipt is removed only
    /// after `recordUploaded` succeeds; any error or cancellation preserves the current receipt and
    /// prevents callers from treating the old queue as disposable scratch.
    @discardableResult
    public func settleAll() async throws -> Int {
        var settled = 0
        while true {
            try Task.checkCancellation()
            let entries = try queue.entriesWithRemoteCommitReconciliation(limit: Self.batchSize)
            guard queue.isOperational() else { throw UploadRemoteCommitRecoveryError.storeUnavailable }
            guard !entries.isEmpty else { return settled }
            for entry in entries {
                try Task.checkCancellation()
                try await settle(entry)
                settled += 1
            }
        }
    }

    private func settle(_ entry: UploadBackupSyncQueueEntry) async throws {
        guard let reconciliation = entry.remoteCommitReconciliation else {
            throw UploadRemoteCommitRecoveryError.malformedReceipt(entry.source, entry.revision)
        }
        guard reconciliation.source.kind == entry.source.kind,
            reconciliation.source.identifier == entry.source.identifier,
            !reconciliation.receipt.remoteVolumeID.isEmpty,
            !reconciliation.receipt.remoteLinkID.isEmpty,
            !reconciliation.identity.nameHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !reconciliation.identity.contentHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            reconciliation.identity.sha1Digest.count == 20,
            UploadContentSHA1.hexString(digest: reconciliation.identity.sha1Digest)
                == reconciliation.identity.sha1Hex.lowercased()
        else {
            throw UploadRemoteCommitRecoveryError.invalidReceipt(entry.source, entry.revision)
        }

        if let snapshot = reconciliation.descriptor {
            guard let queueBinding = reconciliation.queueBinding,
                queueBinding.source == entry.source,
                queueBinding.revision == entry.revision
            else {
                throw UploadRemoteCommitRecoveryError.invalidReceipt(entry.source, entry.revision)
            }
            guard let descriptor = snapshot.descriptor else {
                throw UploadRemoteCommitRecoveryError.descriptorMismatch(entry.source, entry.revision)
            }
            try validateQueueBinding(descriptor, entry: entry)
            try validate(
                descriptor,
                reconciliation: reconciliation,
                entry: entry,
                requireDigestMatch: false
            )
            try await recordAndRemove(descriptor, reconciliation: reconciliation, entry: entry)
            return
        }

        guard let resolved = try await resolver.resolve(entry) else {
            throw UploadRemoteCommitRecoveryError.descriptorUnavailable(entry.source, entry.revision)
        }
        defer { resolved.cleanup?() }
        guard resolved.candidate.snapshot.source == entry.source,
            resolved.candidate.snapshot.revision == entry.revision
        else {
            throw UploadRemoteCommitRecoveryError.descriptorMismatch(entry.source, entry.revision)
        }
        let descriptor: UploadResourceDescriptor?
        if resolved.descriptor.source == reconciliation.source {
            descriptor = resolved.descriptor
        } else {
            descriptor = resolved.secondaries.first { $0.descriptor.source == reconciliation.source }?.descriptor
        }
        guard let descriptor else {
            throw UploadRemoteCommitRecoveryError.descriptorUnavailable(entry.source, entry.revision)
        }
        try validate(
            descriptor,
            reconciliation: reconciliation,
            entry: entry,
            requireDigestMatch: true
        )
        try await recordAndRemove(descriptor, reconciliation: reconciliation, entry: entry)
    }

    private func validateQueueBinding(
        _ descriptor: UploadResourceDescriptor,
        entry: UploadBackupSyncQueueEntry
    ) throws {
        if descriptor.source == entry.source {
            guard descriptor.filename == entry.originalFilename,
                entry.byteCount.map({ $0 == descriptor.fileSize }) ?? true
            else {
                throw UploadRemoteCommitRecoveryError.descriptorMismatch(entry.source, entry.revision)
            }
            return
        }

        guard descriptor.source.kind == entry.source.kind,
            descriptor.source.identifier == entry.source.identifier,
            descriptor.source.resource != .primary,
            descriptor.source.resource != entry.source.resource
        else {
            throw UploadRemoteCommitRecoveryError.descriptorMismatch(entry.source, entry.revision)
        }
    }

    private func validate(
        _ descriptor: UploadResourceDescriptor,
        reconciliation: UploadRemoteCommitReconciliation,
        entry: UploadBackupSyncQueueEntry,
        requireDigestMatch: Bool
    ) throws {
        guard descriptor.source == reconciliation.source,
            ProtonPhotoNameCorrection.correctedName(for: descriptor.filename) == reconciliation.identity.correctedName,
            !descriptor.filename.isEmpty,
            descriptor.fileSize >= 0
        else {
            throw UploadRemoteCommitRecoveryError.descriptorMismatch(entry.source, entry.revision)
        }
        if requireDigestMatch {
            guard descriptor.precomputedSHA1Digest == reconciliation.identity.sha1Digest else {
                throw UploadRemoteCommitRecoveryError.descriptorMismatch(entry.source, entry.revision)
            }
        } else if let digest = descriptor.precomputedSHA1Digest,
            digest != reconciliation.identity.sha1Digest
        {
            throw UploadRemoteCommitRecoveryError.descriptorMismatch(entry.source, entry.revision)
        }
    }

    private func recordAndRemove(
        _ descriptor: UploadResourceDescriptor,
        reconciliation: UploadRemoteCommitReconciliation,
        entry: UploadBackupSyncQueueEntry
    ) async throws {
        try await identityResolver.recordUploaded(
            descriptor,
            identity: reconciliation.identity,
            remoteVolumeID: reconciliation.receipt.remoteVolumeID,
            remoteLinkID: reconciliation.receipt.remoteLinkID
        )
        try Task.checkCancellation()
        guard queue.remove(source: entry.source, revision: entry.revision), queue.isOperational() else {
            throw UploadRemoteCommitRecoveryError.receiptRemovalFailed(entry.source, entry.revision)
        }
    }
}
