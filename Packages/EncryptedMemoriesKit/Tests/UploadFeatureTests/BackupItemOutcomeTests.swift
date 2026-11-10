import Foundation
import PhotosCore
import Testing
import UploadCore

/// Pins what a person sees for every stored queue row: section category, reason, and whether a retry can help.
@Suite
struct BackupItemOutcomeTests {
    /// States whose own value changes the outcome. Every other state gives the outcome of `discovered`.
    private static let distinctStates: [UploadBackupSyncQueueState] = [
        .discovered, .blockedByDraft, .failed, .failedPermanent, .sourceMissing, .skippedRemoteDeletion,
    ]

    private static let allKinds: [BackupIssueKind] = [
        .network, .deviceStorage, .remoteDraft, .remoteDraftStale, .sourceMissing, .permission, .unsupported,
        .remoteService, .localState, .remoteDeletion, .deletedElsewhere, .accountStorage, .unknown,
    ]

    /// Stored `last_error` values: a record of each kind, the persisted wait details, and the formats of older builds.
    private static let storedReasons: [(label: String, lastError: String?)] =
        allKinds.map { ($0.rawValue, BackupIssueRecord(kind: $0, detail: "PRIVATE DETAIL").persistedValue) }
        + [
            ("notReady", "error.upload_source_not_ready"),
            ("unavailable", "backup.issue_source_unavailable"),
            ("reportedMissing", "backup.issue_source_unavailable.reported_missing"),
            ("original", "backup.issue_waiting_original"),
            ("originalEN", "The edited photo is waiting for its original resources. Backup will retry automatically."),
            (
                "originalDE",
                "Das bearbeitete Foto wartet auf seine Originalressourcen. Das Backup versucht es automatisch erneut."
            ),
        ].map { ("unknown/\($0.0)", BackupIssueRecord(kind: .unknown, detail: $0.1).persistedValue) }
        + [
            ("none", nil),
            ("plain-text", "PRIVATE SERVER TEXT"),
            ("damaged-record", BackupIssueRecord.storagePrefix + "not base64"),
        ]

    private static let reasonKeys = [
        "issue_network", "issue_device_storage", "issue_remote_draft", "issue_remote_draft_stale",
        "issue_source_missing", "issue_permission", "issue_unsupported", "issue_remote_service",
        "error_local_state_unavailable", "state_skipped_remote_deletion", "issue_deleted_elsewhere",
        "issue_account_storage", "fail_reason_generic", "issue_permanent", "issue_waiting_original",
        "issue_source_unavailable", "issue_source_not_ready", "issue_unknown_waiting",
    ]

    private static func describe(_ item: BackupFailedItem) -> String {
        let key = reasonKeys.first { L10n.string(dynamicKey: "backup." + $0) == item.reason } ?? "UNMAPPED"
        let retry = item.isPermanent ? "permanent" : item.isRetryable ? "retryable" : "notRetryable"
        #expect(!item.isPermanent || !item.isRetryable)
        return "\(item.category.rawValue) \(key) \(retry)"
    }

    private static func item(state: UploadBackupSyncQueueState, lastError: String?) -> BackupFailedItem {
        BackupFailedItem(
            entry: UploadBackupSyncQueueEntry(
                source: .init(kind: .photoLibraryAsset, identifier: "photo"), revision: .init(rawValue: 1),
                originalFilename: "photo.heic", state: state, lastError: lastError, updatedAt: Date()))
    }

    @Test func everyStoredRowKeepsItsOutcome() {
        let actual = Self.distinctStates.flatMap { state in
            Self.storedReasons.map { reason in
                let item = Self.item(state: state, lastError: reason.lastError)
                return "\(state.rawValue) \(reason.label) -> \(Self.describe(item))"
            }
        }
        #expect(actual == Self.storedRowOutcomes)
    }

    @Test(arguments: UploadBackupSyncQueueState.allCases.filter { !distinctStates.contains($0) })
    func everyOtherStateKeepsTheOutcomeOfAWaitingRow(state: UploadBackupSyncQueueState) {
        for reason in Self.storedReasons {
            #expect(
                Self.describe(Self.item(state: state, lastError: reason.lastError))
                    == Self.describe(Self.item(state: .discovered, lastError: reason.lastError)), "\(reason.label)")
        }
    }

    /// Album Sync rows and the album last-run file carry a reason without a queue row.
    @Test func aReasonWithoutARowKeepsItsOutcome() {
        let actual = Self.allKinds.map { kind in
            let item = BackupFailedItem(
                id: "photo", filename: "photo.heic", reason: "", isPermanent: false, issue: kind)
            let retry = item.isPermanent ? "permanent" : item.isRetryable ? "retryable" : "notRetryable"
            return "\(kind.rawValue) -> \(item.category.rawValue) \(retry)"
        }
        #expect(
            actual == [
                "network -> automatic retryable", "deviceStorage -> automatic retryable",
                "remoteDraft -> automatic retryable", "remoteDraftStale -> permanent permanent",
                "sourceMissing -> permanent permanent", "permission -> userResolvable notRetryable",
                "unsupported -> permanent permanent", "remoteService -> automatic retryable",
                "localState -> userResolvable retryable", "remoteDeletion -> decision notRetryable",
                "deletedElsewhere -> decision notRetryable", "accountStorage -> userResolvable retryable",
                "unknown -> userResolvable retryable",
            ])
    }

    private static let storedRowOutcomes = [
        "discovered network -> automatic issue_network retryable",
        "discovered deviceStorage -> automatic issue_device_storage retryable",
        "discovered remoteDraft -> automatic issue_remote_draft retryable",
        "discovered remoteDraftStale -> permanent issue_remote_draft_stale permanent",
        "discovered sourceMissing -> permanent issue_source_missing permanent",
        "discovered permission -> userResolvable issue_permission notRetryable",
        "discovered unsupported -> permanent issue_unsupported permanent",
        "discovered remoteService -> automatic issue_remote_service retryable",
        "discovered localState -> userResolvable error_local_state_unavailable retryable",
        "discovered remoteDeletion -> decision state_skipped_remote_deletion notRetryable",
        "discovered deletedElsewhere -> decision issue_deleted_elsewhere notRetryable",
        "discovered accountStorage -> userResolvable issue_account_storage retryable",
        "discovered unknown -> automatic issue_unknown_waiting retryable",
        "discovered unknown/notReady -> automatic issue_source_not_ready retryable",
        "discovered unknown/unavailable -> automatic issue_source_unavailable retryable",
        "discovered unknown/reportedMissing -> automatic issue_source_unavailable retryable",
        "discovered unknown/original -> automatic issue_waiting_original retryable",
        "discovered unknown/originalEN -> automatic issue_waiting_original retryable",
        "discovered unknown/originalDE -> automatic issue_waiting_original retryable",
        "discovered none -> automatic issue_unknown_waiting retryable",
        "discovered plain-text -> automatic issue_unknown_waiting retryable",
        "discovered damaged-record -> automatic issue_unknown_waiting retryable",
        "blockedByDraft network -> automatic issue_network retryable",
        "blockedByDraft deviceStorage -> automatic issue_device_storage retryable",
        "blockedByDraft remoteDraft -> automatic issue_remote_draft retryable",
        "blockedByDraft remoteDraftStale -> permanent issue_remote_draft_stale permanent",
        "blockedByDraft sourceMissing -> permanent issue_source_missing permanent",
        "blockedByDraft permission -> userResolvable issue_permission notRetryable",
        "blockedByDraft unsupported -> permanent issue_unsupported permanent",
        "blockedByDraft remoteService -> automatic issue_remote_service retryable",
        "blockedByDraft localState -> userResolvable error_local_state_unavailable retryable",
        "blockedByDraft remoteDeletion -> decision state_skipped_remote_deletion notRetryable",
        "blockedByDraft deletedElsewhere -> decision issue_deleted_elsewhere notRetryable",
        "blockedByDraft accountStorage -> userResolvable issue_account_storage retryable",
        "blockedByDraft unknown -> automatic issue_unknown_waiting retryable",
        "blockedByDraft unknown/notReady -> automatic issue_source_not_ready retryable",
        "blockedByDraft unknown/unavailable -> automatic issue_source_unavailable retryable",
        "blockedByDraft unknown/reportedMissing -> automatic issue_source_unavailable retryable",
        "blockedByDraft unknown/original -> automatic issue_waiting_original retryable",
        "blockedByDraft unknown/originalEN -> automatic issue_waiting_original retryable",
        "blockedByDraft unknown/originalDE -> automatic issue_waiting_original retryable",
        "blockedByDraft none -> automatic issue_remote_draft retryable",
        "blockedByDraft plain-text -> automatic issue_remote_draft retryable",
        "blockedByDraft damaged-record -> automatic issue_unknown_waiting retryable",
        "failed network -> userResolvable issue_network retryable",
        "failed deviceStorage -> userResolvable issue_device_storage retryable",
        "failed remoteDraft -> userResolvable issue_remote_draft retryable",
        "failed remoteDraftStale -> permanent issue_remote_draft_stale permanent",
        "failed sourceMissing -> permanent issue_source_missing permanent",
        "failed permission -> userResolvable issue_permission notRetryable",
        "failed unsupported -> permanent issue_unsupported permanent",
        "failed remoteService -> userResolvable issue_remote_service retryable",
        "failed localState -> userResolvable error_local_state_unavailable retryable",
        "failed remoteDeletion -> decision state_skipped_remote_deletion notRetryable",
        "failed deletedElsewhere -> decision issue_deleted_elsewhere notRetryable",
        "failed accountStorage -> userResolvable issue_account_storage retryable",
        "failed unknown -> userResolvable fail_reason_generic retryable",
        "failed unknown/notReady -> automatic issue_source_not_ready retryable",
        "failed unknown/unavailable -> automatic issue_source_unavailable retryable",
        "failed unknown/reportedMissing -> automatic issue_source_unavailable retryable",
        "failed unknown/original -> automatic issue_waiting_original retryable",
        "failed unknown/originalEN -> automatic issue_waiting_original retryable",
        "failed unknown/originalDE -> automatic issue_waiting_original retryable",
        "failed none -> userResolvable fail_reason_generic retryable",
        "failed plain-text -> userResolvable fail_reason_generic retryable",
        "failed damaged-record -> userResolvable fail_reason_generic retryable",
        "failedPermanent network -> permanent issue_permanent permanent",
        "failedPermanent deviceStorage -> permanent issue_permanent permanent",
        "failedPermanent remoteDraft -> permanent issue_permanent permanent",
        "failedPermanent remoteDraftStale -> permanent issue_remote_draft_stale permanent",
        "failedPermanent sourceMissing -> permanent issue_source_missing permanent",
        "failedPermanent permission -> permanent issue_permanent permanent",
        "failedPermanent unsupported -> permanent issue_unsupported permanent",
        "failedPermanent remoteService -> permanent issue_permanent permanent",
        "failedPermanent localState -> permanent issue_permanent permanent",
        "failedPermanent remoteDeletion -> permanent issue_permanent permanent",
        "failedPermanent deletedElsewhere -> decision issue_deleted_elsewhere permanent",
        "failedPermanent accountStorage -> permanent issue_permanent permanent",
        "failedPermanent unknown -> permanent issue_permanent permanent",
        "failedPermanent unknown/notReady -> permanent issue_permanent permanent",
        "failedPermanent unknown/unavailable -> permanent issue_permanent permanent",
        "failedPermanent unknown/reportedMissing -> permanent issue_permanent permanent",
        "failedPermanent unknown/original -> permanent issue_permanent permanent",
        "failedPermanent unknown/originalEN -> permanent issue_permanent permanent",
        "failedPermanent unknown/originalDE -> permanent issue_permanent permanent",
        "failedPermanent none -> permanent issue_remote_draft_stale permanent",
        "failedPermanent plain-text -> permanent issue_remote_draft_stale permanent",
        "failedPermanent damaged-record -> permanent issue_permanent permanent",
        "sourceMissing network -> permanent issue_permanent permanent",
        "sourceMissing deviceStorage -> permanent issue_permanent permanent",
        "sourceMissing remoteDraft -> permanent issue_permanent permanent",
        "sourceMissing remoteDraftStale -> permanent issue_remote_draft_stale permanent",
        "sourceMissing sourceMissing -> permanent issue_source_missing permanent",
        "sourceMissing permission -> permanent issue_permanent permanent",
        "sourceMissing unsupported -> permanent issue_unsupported permanent",
        "sourceMissing remoteService -> permanent issue_permanent permanent",
        "sourceMissing localState -> permanent issue_permanent permanent",
        "sourceMissing remoteDeletion -> permanent issue_permanent permanent",
        "sourceMissing deletedElsewhere -> decision issue_deleted_elsewhere permanent",
        "sourceMissing accountStorage -> permanent issue_permanent permanent",
        "sourceMissing unknown -> permanent issue_permanent permanent",
        "sourceMissing unknown/notReady -> permanent issue_permanent permanent",
        "sourceMissing unknown/unavailable -> permanent issue_permanent permanent",
        "sourceMissing unknown/reportedMissing -> permanent issue_permanent permanent",
        "sourceMissing unknown/original -> permanent issue_permanent permanent",
        "sourceMissing unknown/originalEN -> permanent issue_permanent permanent",
        "sourceMissing unknown/originalDE -> permanent issue_permanent permanent",
        "sourceMissing none -> permanent issue_source_missing permanent",
        "sourceMissing plain-text -> permanent issue_source_missing permanent",
        "sourceMissing damaged-record -> permanent issue_permanent permanent",
        "skippedRemoteDeletion network -> automatic issue_network retryable",
        "skippedRemoteDeletion deviceStorage -> automatic issue_device_storage retryable",
        "skippedRemoteDeletion remoteDraft -> automatic issue_remote_draft retryable",
        "skippedRemoteDeletion remoteDraftStale -> permanent issue_remote_draft_stale permanent",
        "skippedRemoteDeletion sourceMissing -> permanent issue_source_missing permanent",
        "skippedRemoteDeletion permission -> userResolvable issue_permission notRetryable",
        "skippedRemoteDeletion unsupported -> permanent issue_unsupported permanent",
        "skippedRemoteDeletion remoteService -> automatic issue_remote_service retryable",
        "skippedRemoteDeletion localState -> userResolvable error_local_state_unavailable retryable",
        "skippedRemoteDeletion remoteDeletion -> decision state_skipped_remote_deletion notRetryable",
        "skippedRemoteDeletion deletedElsewhere -> decision issue_deleted_elsewhere notRetryable",
        "skippedRemoteDeletion accountStorage -> userResolvable issue_account_storage retryable",
        "skippedRemoteDeletion unknown -> automatic issue_unknown_waiting retryable",
        "skippedRemoteDeletion unknown/notReady -> automatic issue_source_not_ready retryable",
        "skippedRemoteDeletion unknown/unavailable -> automatic issue_source_unavailable retryable",
        "skippedRemoteDeletion unknown/reportedMissing -> automatic issue_source_unavailable retryable",
        "skippedRemoteDeletion unknown/original -> automatic issue_waiting_original retryable",
        "skippedRemoteDeletion unknown/originalEN -> automatic issue_waiting_original retryable",
        "skippedRemoteDeletion unknown/originalDE -> automatic issue_waiting_original retryable",
        "skippedRemoteDeletion none -> decision state_skipped_remote_deletion notRetryable",
        "skippedRemoteDeletion plain-text -> decision state_skipped_remote_deletion notRetryable",
        "skippedRemoteDeletion damaged-record -> automatic issue_unknown_waiting retryable",
    ]
}
