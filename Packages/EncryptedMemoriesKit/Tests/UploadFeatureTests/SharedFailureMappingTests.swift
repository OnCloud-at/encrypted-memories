import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class SharedFailureMappingTests: XCTestCase {
    func testUploadAndFolderCauses() {
        XCTAssertEqual(UploadError.transport(code: -1009, message: "").failureCause, .network)
        XCTAssertEqual(UploadError.cancelled.failureCause, .cancelled)
        XCTAssertEqual(UploadError.unsupportedFile("x").failureCause, .unsupported)
        XCTAssertEqual(UploadError.backend("unknown").failureCause, .unknown)
        let error = FolderEnumerationError(
            operation: .readDirectory, url: URL(fileURLWithPath: "/"),
            failureClass: .permissionDenied, domain: "", code: 0)
        XCTAssertEqual(error.failureCause, .permission)
        XCTAssertEqual(UploadRemoteCommitRecoveryError.storeUnavailable.failureCause, .localState)
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
    func testBackupSpaceReasonsStayDistinct() {
        XCTAssertEqual(
            BackupTempFileStore.BackupTempFileError.needsFreeSpace(requiredBytes: 10).failureCause, .deviceStorage)
        XCTAssertEqual(BackupTempFileStore.BackupTempFileError.diskBudgetExceeded.failureCause, .unknown)
    }
    func testRecoveryDescriptorDoesNotClaimStoreFailure() {
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "test")
        let revision = UploadBackupRevision(rawValue: 1)
        XCTAssertEqual(UploadRemoteCommitRecoveryError.descriptorUnavailable(source, revision).failureCause, .unknown)
        XCTAssertEqual(UploadRemoteCommitRecoveryError.descriptorMismatch(source, revision).failureCause, .unknown)
    }
    func testCommittedUploadNeedsReconciliationEvenWhenCancelled() {
        let receipt = UploadRemoteCommitReceipt(remoteVolumeID: "v", remoteLinkID: "l")
        let error = UploadRemoteCommitSettlementError(
            receipt: receipt, settlementMessage: "", cancellation: CancellationError())
        XCTAssertEqual(error.failureCause, .partialCompletion)
        XCTAssertEqual(FailurePolicy.resolve(error.failureCause, context: .mutation).retryPolicy, .afterReconciliation)
    }
}
