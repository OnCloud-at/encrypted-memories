import PhotosCore

/// Records the pending handoff before the identity manifest. Callers retain their own failure policy and receipt cleanup.
enum UploadRemoteCommitRecording {
    /// False means that the handoff or descriptor was refused; the caller must keep the receipt.
    /// Calls `descriptorOrPark` only after the handoff. Before returning nil, the closure handles
    /// the unavailable descriptor; the runner parks its queue row there.
    static func record(
        _ reconciliation: UploadRemoteCommitReconciliation,
        for entry: UploadBackupSyncQueueEntry,
        events: (any BackupItemEventSink)?,
        identityResolver: any UploadIdentityResolving,
        descriptorOrPark: () -> UploadResourceDescriptor?,
        onHandoffFailure: () throws -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Bool {
        if reconciliation.source == entry.source,
            events?.recordHandoff(
                source: entry.source,
                revision: entry.revision,
                remote: PhotoUID(
                    volumeID: reconciliation.receipt.remoteVolumeID,
                    nodeID: reconciliation.receipt.remoteLinkID
                ),
                kind: .uploaded
            ) == .failed
        {
            try onHandoffFailure()
            return false
        }
        guard let descriptor = descriptorOrPark() else { return false }
        try await identityResolver.recordUploaded(
            descriptor,
            identity: reconciliation.identity,
            remoteVolumeID: reconciliation.receipt.remoteVolumeID,
            remoteLinkID: reconciliation.receipt.remoteLinkID
        )
        return true
    }
}
