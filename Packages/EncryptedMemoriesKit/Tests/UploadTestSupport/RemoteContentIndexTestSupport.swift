import Foundation
import UploadCore

extension UploadIdentityManifestStore {
    /// Stores a complete content index in one full build, for tests that need an index in a known state. It runs
    /// only the public build steps (`begin`, one `append`, `finish`), so it has no SQL of its own. It is not atomic:
    /// the steps are three transactions, a failed finish leaves the build checkpoint, the epoch of the records and
    /// proofs is checked only after `begin` committed, and records with an empty hash or link pass.
    @discardableResult
    package func seedRemoteContentIndex(
        _ records: [UploadRemoteContentIndexRecord],
        remoteAssetRecords: [UploadRemoteAssetIndexRecord] = [],
        unresolvedIssues: [UploadRemoteContentIndexIssue],
        hashKeyEpoch: String,
        checkpoint: UploadRemoteContentIndexCheckpoint
    ) -> Bool {
        guard
            let build = beginRemoteContentIndexBuild(
                hashKeyEpoch: hashKeyEpoch, eventID: checkpoint.eventID, sourceFingerprint: UUID().uuidString,
                total: records.count, updatedAt: checkpoint.refreshedAt)
        else { return false }
        return appendRemoteContentIndexBuild(
            records: records, unresolvedIssues: unresolvedIssues, externalIdentities: [], hashKeyEpoch: hashKeyEpoch,
            buildID: build.buildID, nextCursor: records.count, updatedAt: checkpoint.refreshedAt)
            && finishRemoteContentIndexBuild(
                remoteAssetRecords: remoteAssetRecords, hashKeyEpoch: hashKeyEpoch, buildID: build.buildID,
                checkpoint: checkpoint)
    }
}
