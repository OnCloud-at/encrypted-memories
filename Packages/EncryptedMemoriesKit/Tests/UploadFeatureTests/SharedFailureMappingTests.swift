import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class SharedFailureMappingTests: XCTestCase {
    func testUploadAndFolderCauses() {
        XCTAssertEqual(UploadError.transport(code: -1009, message: "").failureCause, .network)
        XCTAssertEqual(UploadError.cancelled.failureCause, .cancelled)
        XCTAssertTrue(UploadError.isCancellation(CancellationError()))
        XCTAssertTrue(UploadError.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(UploadError.isCancellation(URLError(.timedOut)))
        XCTAssertEqual(UploadError.unsupportedFile("x").failureCause, .unsupported)
        XCTAssertEqual(UploadError.backend("unknown").failureCause, .unknown)
        let error = FolderEnumerationError(
            operation: .readDirectory, url: URL(fileURLWithPath: "/"),
            failureClass: .permissionDenied, domain: "", code: 0)
        XCTAssertEqual(error.failureCause, .permission)
        XCTAssertEqual(UploadRemoteCommitRecoveryError.storeUnavailable.failureCause, .partialCompletion)
    }

    func testStoredBackupReasonValuesRemainStable() throws {
        let cases: [(BackupIssueKind, String)] = [
            (.network, "network"), (.deviceStorage, "deviceStorage"), (.remoteDraft, "remoteDraft"),
            (.remoteDraftStale, "remoteDraftStale"), (.sourceMissing, "sourceMissing"), (.permission, "permission"),
            (.unsupported, "unsupported"), (.remoteService, "remoteService"), (.localState, "localState"),
            (.remoteDeletion, "remoteDeletion"), (.deletedElsewhere, "deletedElsewhere"),
            (.accountStorage, "accountStorage"), (.unknown, "unknown"),
        ]
        for (kind, stored) in cases {
            XCTAssertEqual(kind.rawValue, stored)
            XCTAssertEqual(String(decoding: try JSONEncoder().encode(kind), as: UTF8.self), "\"\(stored)\"")
            XCTAssertEqual(try JSONDecoder().decode(BackupIssueKind.self, from: Data("\"\(stored)\"".utf8)), kind)
            let record = BackupIssueRecord(kind: kind, detail: "detail")
            XCTAssertEqual(BackupIssueRecord.decode(record.persistedValue), record)
        }
        let fixtures: [(BackupIssueKind, String)] = [
            (
                .network,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoibmV0d29yayIsImRldGFpbCI6ImxlZ2FjeSIsImF1dG9tYXRpY1JldHJ5QXR0ZW1wdCI6MH0="
            ),
            (
                .deviceStorage,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoiZGV2aWNlU3RvcmFnZSIsImRldGFpbCI6ImxlZ2FjeSIsImF1dG9tYXRpY1JldHJ5QXR0ZW1wdCI6MH0="
            ),
            (
                .remoteDraft,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoicmVtb3RlRHJhZnQiLCJkZXRhaWwiOiJsZWdhY3kiLCJhdXRvbWF0aWNSZXRyeUF0dGVtcHQiOjB9"
            ),
            (
                .remoteDraftStale,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoicmVtb3RlRHJhZnRTdGFsZSIsImRldGFpbCI6ImxlZ2FjeSIsImF1dG9tYXRpY1JldHJ5QXR0ZW1wdCI6MH0="
            ),
            (
                .sourceMissing,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoic291cmNlTWlzc2luZyIsImRldGFpbCI6ImxlZ2FjeSIsImF1dG9tYXRpY1JldHJ5QXR0ZW1wdCI6MH0="
            ),
            (
                .permission,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoicGVybWlzc2lvbiIsImRldGFpbCI6ImxlZ2FjeSIsImF1dG9tYXRpY1JldHJ5QXR0ZW1wdCI6MH0="
            ),
            (
                .unsupported,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoidW5zdXBwb3J0ZWQiLCJkZXRhaWwiOiJsZWdhY3kiLCJhdXRvbWF0aWNSZXRyeUF0dGVtcHQiOjB9"
            ),
            (
                .remoteService,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoicmVtb3RlU2VydmljZSIsImRldGFpbCI6ImxlZ2FjeSIsImF1dG9tYXRpY1JldHJ5QXR0ZW1wdCI6MH0="
            ),
            (
                .localState,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoibG9jYWxTdGF0ZSIsImRldGFpbCI6ImxlZ2FjeSIsImF1dG9tYXRpY1JldHJ5QXR0ZW1wdCI6MH0="
            ),
            (
                .remoteDeletion,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoicmVtb3RlRGVsZXRpb24iLCJkZXRhaWwiOiJsZWdhY3kiLCJhdXRvbWF0aWNSZXRyeUF0dGVtcHQiOjB9"
            ),
            (
                .deletedElsewhere,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoiZGVsZXRlZEVsc2V3aGVyZSIsImRldGFpbCI6ImxlZ2FjeSIsImF1dG9tYXRpY1JldHJ5QXR0ZW1wdCI6MH0="
            ),
            (
                .accountStorage,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoiYWNjb3VudFN0b3JhZ2UiLCJkZXRhaWwiOiJsZWdhY3kiLCJhdXRvbWF0aWNSZXRyeUF0dGVtcHQiOjB9"
            ),
            (
                .unknown,
                "encryptedmemories-backup-issue-v1:eyJraW5kIjoidW5rbm93biIsImRldGFpbCI6ImxlZ2FjeSIsImF1dG9tYXRpY1JldHJ5QXR0ZW1wdCI6MH0="
            ),
        ]
        for (kind, literal) in fixtures {
            let record = try XCTUnwrap(BackupIssueRecord.decode(literal))
            XCTAssertEqual(record.kind, kind)
            XCTAssertEqual(record.detail, "legacy")
            XCTAssertNil(record.nextAttemptAt)
            XCTAssertEqual(record.automaticRetryAttempt, 0)
        }
        XCTAssertEqual(try JSONDecoder().decode(BackupIssueKind.self, from: Data("\"future\"".utf8)), .unknown)
    }

    func testBackupIssueCausesKeepUnknownDistinct() {
        XCTAssertEqual(BackupIssueKind.network.failureCause, .network)
        XCTAssertEqual(BackupIssueKind.accountStorage.failureCause, .accountStorage)
        XCTAssertEqual(BackupIssueKind.deletedElsewhere.failureCause, .userDecision)
        XCTAssertEqual(BackupIssueKind.unknown.failureCause, .unknown)
        // Both stored reasons combine more than one producer; they cannot prove a transient or permanent cause.
        XCTAssertEqual(BackupIssueKind.remoteService.failureCause, .unknown)
        XCTAssertEqual(BackupIssueKind.sourceMissing.failureCause, .unknown)
    }
    func testSeriesFailurePreservesAmbiguity() {
        XCTAssertEqual(SeriesDissolutionError.notOwnLibrary.failureCause, .unknown)
        XCTAssertEqual(SeriesDissolutionError.invalidSelection.failureCause, .userDecision)
        XCTAssertEqual(SeriesDissolutionError.libraryUnavailable.failureCause, .localState)
    }
    func testBackupSpaceReasonsBothMapToDeviceStorage() {
        XCTAssertEqual(
            BackupTempFileStore.BackupTempFileError.needsFreeSpace(requiredBytes: 10).failureCause, .deviceStorage)
        XCTAssertEqual(BackupTempFileStore.BackupTempFileError.diskBudgetExceeded.failureCause, .deviceStorage)
    }
    func testRecoveryDescriptorDoesNotClaimStoreFailure() {
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "test")
        let revision = UploadBackupRevision(rawValue: 1)
        XCTAssertEqual(
            UploadRemoteCommitRecoveryError.descriptorUnavailable(source, revision).failureCause, .partialCompletion)
        XCTAssertEqual(
            UploadRemoteCommitRecoveryError.descriptorMismatch(source, revision).failureCause, .partialCompletion)
    }
    func testCommittedUploadNeedsReconciliationEvenWhenCancelled() {
        let receipt = UploadRemoteCommitReceipt(remoteVolumeID: "v", remoteLinkID: "l")
        let error = UploadRemoteCommitSettlementError(
            receipt: receipt, settlementMessage: "", cancellation: CancellationError())
        XCTAssertEqual(error.failureCause, .partialCompletion)
        XCTAssertEqual(
            FailurePolicy.resolve(error.failureCause, situation: .background, safety: .mutation).retry,
            .afterReconciliation)
    }
    func testUploadAndBackupCauseGroups() {
        XCTAssertEqual(
            UploadError.accountStorageFull("x", requiredBytes: 10, availableBytes: 1).failureCause, .accountStorage)
        XCTAssertEqual(UploadError.permissionDenied("x").failureCause, .permission)
        XCTAssertEqual(UploadError.retryableBackend(code: 503, message: "").failureCause, .serviceTemporary)
        XCTAssertEqual(UploadError.sourceUnavailable("x").failureCause, .sourceTemporarilyUnavailable)
        XCTAssertEqual(
            UploadError.sourceNotReady("x", until: Date(timeIntervalSince1970: 0)).failureCause,
            .sourceTemporarilyUnavailable)
        XCTAssertEqual(UploadError.tagAdderUnavailable.failureCause, .localState)
        XCTAssertEqual(UploadError.transport(code: URLError.cancelled.rawValue, message: "").failureCause, .cancelled)
        XCTAssertEqual(BackupIssueKind.permission.failureCause, .permission)
        XCTAssertEqual(BackupIssueKind.deviceStorage.failureCause, .deviceStorage)
        XCTAssertEqual(BackupIssueKind.unsupported.failureCause, .unsupported)
        XCTAssertEqual(BackupIssueKind.localState.failureCause, .localState)
        XCTAssertEqual(BackupIssueKind.remoteDeletion.failureCause, .userDecision)
        XCTAssertEqual(BackupIssueKind.remoteDraft.failureCause, .unknown)
        XCTAssertEqual(BackupIssueKind.remoteDraftStale.failureCause, .permanent)
    }

    func testEveryRecoveryErrorAndFolderClass() {
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "test")
        let revision = UploadBackupRevision(rawValue: 1)
        XCTAssertEqual(UploadRemoteCommitRecoveryError.storeUnavailable.failureCause, .partialCompletion)
        XCTAssertEqual(UploadRemoteCommitRecoveryError.malformedReceipt(source, revision).failureCause, .permanent)
        XCTAssertEqual(UploadRemoteCommitRecoveryError.invalidReceipt(source, revision).failureCause, .permanent)
        XCTAssertEqual(
            UploadRemoteCommitRecoveryError.descriptorUnavailable(source, revision).failureCause, .partialCompletion)
        XCTAssertEqual(
            UploadRemoteCommitRecoveryError.descriptorMismatch(source, revision).failureCause, .partialCompletion)
        XCTAssertEqual(
            UploadRemoteCommitRecoveryError.receiptRemovalFailed(source, revision).failureCause, .partialCompletion)
        func folder(_ kind: FolderEnumerationError.FailureClass) -> FolderEnumerationError {
            FolderEnumerationError(
                operation: .readDirectory, url: URL(fileURLWithPath: "/"), failureClass: kind, domain: "", code: 0)
        }
        XCTAssertEqual(folder(.missing).failureCause, .sourceGone)
        XCTAssertEqual(folder(.transient).failureCause, .sourceTemporarilyUnavailable)
    }
}
