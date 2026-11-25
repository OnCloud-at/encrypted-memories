import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// An internal failure shows the text of the old backend error and stores the same row (#1159).
final class InternalFailurePersistedRecordTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "internal-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The text of every case, as the backend error that it replaces wrote it. These texts are stored in the detail of
    /// a row and shown to a person, so they stay as they are.
    private static let texts: [UploadError.InternalFailure: String] = [
        .localStateUnavailable: L10n.string("backup.error_local_state_unavailable"),
        .sourceRecoveryUnavailable: "Backup source recovery is unavailable",
        .preflightClassificationIncomplete: "Backup preflight classification was incomplete",
        .exclusionsUnavailable: "Backup exclusions are unavailable",
        .stateNotRead: "Backup state could not be read",
        .stateBatchNotRead: "Backup state batch could not be read",
        .stateNotSaved: "Backup state could not be saved",
        .stateNotUpdated: "Backup state could not be updated",
        .completionStateNotSaved: "Backup completion state could not be saved",
        .identityManifestNotUpdated: "Upload identity manifest could not be updated",
        .editJournalNotWritten: "Edit replacement journal could not be written",
        .pendingHandoffNotSaved: "Pending handoff could not be persisted",
        .remoteCommitReconciliationNotSaved: "Remote commit reconciliation could not be persisted",
        .secondaryReconciliationNotSaved: "Secondary reconciliation could not be persisted",
        .queueNotUploading: "Backup queue could not enter uploading state",
        .queueNotUpdated: "Backup queue could not be updated",
        .deletionJournalUnavailable: "Deletion journal is unavailable",
        .uploadDecisionWithoutTransport: "Scoped upload decision returned without transport",
        .manualSettlementUnavailable: "Durable manual upload settlement is unavailable.",
        .identityResolverUnavailable: "Upload identity resolver is unavailable for settlement.",
        .receiptBacksTheUpload: "Remote upload receipt exists; byte upload is not retryable.",
        .byteUploadBlocked: "Durable manual upload settlement is unavailable; byte upload is blocked.",
        .manualReceiptNotPersisted: "Manual upload receipt could not be persisted.",
        .managerReleased: "Upload manager was released before receipt persistence.",
        .deletionCheckPending: L10n.string("backup.issue_deletion_check"),
        .remoteDraftExists: L10n.string("upload.error_remote_draft"),
        .remoteInconsistent: L10n.string("upload.error_remote_inconsistent"),
        .relatedPhotosUnavailable: "Related photos of the main photo are unavailable",
        .duplicateIndexUnavailable: "Remote duplicate index is unavailable",
        .duplicateIndexCheckpointNotSaved: "Remote duplicate index checkpoint could not be saved",
        .duplicateIndexNotSaved: "Remote duplicate index could not be saved",
        .duplicateIndexChangesNotSaved: "Remote duplicate index changes could not be saved",
        .identityManifestNotRead: "Upload identity manifest could not be read",
        .duplicateMergeJournalNotUpdated: "Duplicate merge journal could not be updated",
        .mergedDuplicateServerCopyMissing: "No copy of the merged duplicates is on the server",
        .mergedDuplicateLibraryCopyMissing: "No copy of the merged duplicates is in the library",
        .invalidPrecomputedDigest: "Invalid precomputed SHA-1 digest",
        .restoredCompoundCheckingUnavailable: "Restored compound checking is unavailable",
        .noUploadDecisionReceivedRemoteCommit:
            "Upload decision scope received a remote commit for a no-upload decision",
        .uploadDecisionWithoutReceipt: "Upload decision scope ended without a remote commit receipt",
        .copyRoleUnavailable: "The role of a copy with these bytes is unavailable",
        .dedupeProtectionUnavailable: "Duplicate protection is unavailable; upload cannot start safely.",
        .linkVisibilityIncomplete: "The link visibility response is incomplete",
        .photoTagResultOmitted: "SDK omitted the photo tag result",
        .networkReservationMissing: "The upload started without its network reservation",
        .upgradeIdentityStoreNotOpened: "The upgrade identity store did not open",
        .syntheticPhotoUnknown: "Unexpected synthetic photo",
        .photoKitExportFileNotCreated: "PhotoKit export file could not be created",
        .photoResolverUnexpectedSource(kind: .fileURL):
            "photo resolver received source kind \(UploadSourceIdentity.Kind.fileURL.rawValue)",
        .backupResolverUnsupportedSource(kind: .fileURL):
            "unsupported backup source kind \(UploadSourceIdentity.Kind.fileURL.rawValue)",
    ]

    /// The class of every case, written out: a failed read or write of a store or file is a local state; a refusal, a
    /// wait for the remote library, an answer of it that the build cannot use and a defect of the app are unknown.
    private static let causes: [UploadError.InternalFailure: FailureCause] = [
        .localStateUnavailable: .localState,
        .sourceRecoveryUnavailable: .localState,
        .preflightClassificationIncomplete: .localState,
        .exclusionsUnavailable: .localState,
        .stateNotRead: .localState,
        .stateBatchNotRead: .localState,
        .stateNotSaved: .localState,
        .stateNotUpdated: .localState,
        .completionStateNotSaved: .localState,
        .identityManifestNotUpdated: .localState,
        .editJournalNotWritten: .localState,
        .pendingHandoffNotSaved: .localState,
        .remoteCommitReconciliationNotSaved: .localState,
        .secondaryReconciliationNotSaved: .localState,
        .queueNotUploading: .localState,
        .queueNotUpdated: .localState,
        .deletionJournalUnavailable: .unknown,
        .uploadDecisionWithoutTransport: .unknown,
        .manualSettlementUnavailable: .localState,
        .identityResolverUnavailable: .unknown,
        .receiptBacksTheUpload: .unknown,
        .byteUploadBlocked: .localState,
        .manualReceiptNotPersisted: .localState,
        .managerReleased: .unknown,
        .deletionCheckPending: .unknown,
        .remoteDraftExists: .unknown,
        .remoteInconsistent: .unknown,
        .relatedPhotosUnavailable: .unknown,
        .duplicateIndexUnavailable: .unknown,
        .duplicateIndexCheckpointNotSaved: .localState,
        .duplicateIndexNotSaved: .localState,
        .duplicateIndexChangesNotSaved: .localState,
        .identityManifestNotRead: .localState,
        .duplicateMergeJournalNotUpdated: .localState,
        .mergedDuplicateServerCopyMissing: .unknown,
        .mergedDuplicateLibraryCopyMissing: .unknown,
        .invalidPrecomputedDigest: .localState,
        .restoredCompoundCheckingUnavailable: .unknown,
        .noUploadDecisionReceivedRemoteCommit: .unknown,
        .uploadDecisionWithoutReceipt: .unknown,
        .copyRoleUnavailable: .unknown,
        .dedupeProtectionUnavailable: .unknown,
        .linkVisibilityIncomplete: .unknown,
        .photoTagResultOmitted: .unknown,
        .networkReservationMissing: .unknown,
        .upgradeIdentityStoreNotOpened: .localState,
        .syntheticPhotoUnknown: .unknown,
        .photoKitExportFileNotCreated: .localState,
        .photoResolverUnexpectedSource(kind: .fileURL): .unknown,
        .backupResolverUnsupportedSource(kind: .fileURL): .unknown,
    ]

    func testEveryInternalFailureKeepsTheTextOfTheBackendErrorItReplaces() {
        XCTAssertEqual(
            Set(UploadError.InternalFailure.allCases), Set(Self.texts.keys), "a new case needs its text here")
        XCTAssertEqual(
            Set(UploadError.InternalFailure.allCases), Set(Self.causes.keys), "a new case needs its class here")
        for failure in UploadError.InternalFailure.allCases {
            let message = Self.texts[failure]
            XCTAssertEqual(failure.message, message, "\(failure)")
            let cause = Self.causes[failure]
            XCTAssertEqual(failure.failureCause, cause, "\(failure)")
            XCTAssertEqual(UploadError.internalFailure(failure).errorDescription, message, "\(failure)")
            XCTAssertEqual(UploadError.internalFailure(failure).failureCause, cause, "\(failure)")
            XCTAssertEqual(
                UploadError.internalFailure(failure).errorDescription,
                UploadError.backend(message ?? "").errorDescription, "\(failure)")
        }
    }

    /// Runs one photo through the runner whose upload fails with `error`, and returns the stored `lastError` and state.
    private func storedRow(
        after error: any Error
    ) async throws -> (lastError: String?, state: UploadBackupSyncQueueState?) {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent(UUID().uuidString + ".sqlite")))
        defer { queue.close() }
        let clock = BackupTestClock()
        let resolver = ScriptedBackupResolver(defaultModified: clock.now.addingTimeInterval(-3600))
        let preflight = UploadBackupPreflightIndex(store: MemoryBackupStateStore(), now: { clock.now })
        let pipeline = UploadDedupePipeline(
            store: FakeIdentityStore(), hasher: FakeHasher(), checker: FakeChecker(),
            resourceCoordinator: .shared, now: { clock.now })
        let entry = UploadBackupSyncQueueEntry(
            source: .file(URL(fileURLWithPath: "/backup/failing.jpg")),
            revision: UploadBackupRevision(date: resolver.defaultModified), originalFilename: "failing.jpg",
            byteCount: 4, state: .discovered, attempts: 0, updatedAt: clock.now.addingTimeInterval(-60))
        XCTAssertTrue(queue.upsert(entry))
        let runner = BackupSyncRunner(
            queue: queue, preflight: preflight, resolver: resolver, identityResolver: pipeline,
            uploader: ThrowingUploader(error: error), tagAdder: SpyTagAdder(),
            configuration: BackupSyncRunner.Configuration(
                retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 1, maxAttempts: 1),
                throttle: BackupThrottlePolicy(baseConcurrency: 1)),
            clock: clock, now: { clock.now })
        _ = await runner.runUntilDrained()
        let row = try queue.entry(for: entry.source, revision: entry.revision)
        return (row?.lastError, row?.state)
    }

    /// The record that the runner stores for an internal failure equals the record of the backend error with the same text.
    func testTheStoredRowOfAnInternalFailureEqualsTheRowOfTheBackendErrorItReplaces() async throws {
        for failure in UploadError.InternalFailure.allCases {
            let message = try XCTUnwrap(Self.texts[failure], "\(failure)")
            let before = try await storedRow(after: UploadError.backend(message))
            let after = try await storedRow(after: UploadError.internalFailure(failure))

            XCTAssertEqual(after.state, before.state, "the item parks the same way: \(failure)")
            // The encoder writes the keys of the record in no fixed order, so two equal records differ in their bytes.
            // The record that each row decodes to is the value that the app reads.
            let record = try XCTUnwrap(BackupIssueRecord.decode(after.lastError), "\(failure)")
            XCTAssertEqual(record, BackupIssueRecord.decode(before.lastError), "the stored record is equal: \(failure)")
            XCTAssertEqual(record.kind, .remoteService, "the persisted kind of a backend failure: \(failure)")
            XCTAssertEqual(record.detail, message, "\(failure)")
        }
    }
}

/// Fails every upload with one error. The other calls answer like the mock uploader.
private final class ThrowingUploader: PhotoUploading, @unchecked Sendable {
    private let inner = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
    private let error: any Error

    init(error: any Error) { self.error = error }

    var capabilities: UploadBackendCapabilities { inner.capabilities }

    func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
        try await inner.reserveNetwork(allowsExpensiveNetwork: allowsExpensiveNetwork)
    }

    func upload(
        _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        throw error
    }

    func cancel(token: UUID) async { await inner.cancel(token: token) }
    func pause(token: UUID) async throws { try await inner.pause(token: token) }
    func resume(token: UUID) async throws { try await inner.resume(token: token) }
}
