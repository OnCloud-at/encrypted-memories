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
        return "\(item.issue.rawValue) \(item.category.rawValue) \(key) \(retry)"
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
        "discovered network -> network automatic issue_network retryable",
        "discovered deviceStorage -> deviceStorage automatic issue_device_storage retryable",
        "discovered remoteDraft -> remoteDraft automatic issue_remote_draft retryable",
        "discovered remoteDraftStale -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "discovered sourceMissing -> sourceMissing permanent issue_source_missing permanent",
        "discovered permission -> permission userResolvable issue_permission notRetryable",
        "discovered unsupported -> unsupported permanent issue_unsupported permanent",
        "discovered remoteService -> remoteService automatic issue_remote_service retryable",
        "discovered localState -> localState userResolvable error_local_state_unavailable retryable",
        "discovered remoteDeletion -> remoteDeletion decision state_skipped_remote_deletion notRetryable",
        "discovered deletedElsewhere -> deletedElsewhere decision issue_deleted_elsewhere notRetryable",
        "discovered accountStorage -> accountStorage userResolvable issue_account_storage retryable",
        "discovered unknown -> unknown automatic issue_unknown_waiting retryable",
        "discovered unknown/notReady -> unknown automatic issue_source_not_ready retryable",
        "discovered unknown/unavailable -> unknown automatic issue_source_unavailable retryable",
        "discovered unknown/reportedMissing -> unknown automatic issue_source_unavailable retryable",
        "discovered unknown/original -> unknown automatic issue_waiting_original retryable",
        "discovered unknown/originalEN -> unknown automatic issue_waiting_original retryable",
        "discovered unknown/originalDE -> unknown automatic issue_waiting_original retryable",
        "discovered none -> unknown automatic issue_unknown_waiting retryable",
        "discovered plain-text -> unknown automatic issue_unknown_waiting retryable",
        "discovered damaged-record -> unknown automatic issue_unknown_waiting retryable",
        "blockedByDraft network -> network automatic issue_network retryable",
        "blockedByDraft deviceStorage -> deviceStorage automatic issue_device_storage retryable",
        "blockedByDraft remoteDraft -> remoteDraft automatic issue_remote_draft retryable",
        "blockedByDraft remoteDraftStale -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "blockedByDraft sourceMissing -> sourceMissing permanent issue_source_missing permanent",
        "blockedByDraft permission -> permission userResolvable issue_permission notRetryable",
        "blockedByDraft unsupported -> unsupported permanent issue_unsupported permanent",
        "blockedByDraft remoteService -> remoteService automatic issue_remote_service retryable",
        "blockedByDraft localState -> localState userResolvable error_local_state_unavailable retryable",
        "blockedByDraft remoteDeletion -> remoteDeletion decision state_skipped_remote_deletion notRetryable",
        "blockedByDraft deletedElsewhere -> deletedElsewhere decision issue_deleted_elsewhere notRetryable",
        "blockedByDraft accountStorage -> accountStorage userResolvable issue_account_storage retryable",
        "blockedByDraft unknown -> unknown automatic issue_unknown_waiting retryable",
        "blockedByDraft unknown/notReady -> unknown automatic issue_source_not_ready retryable",
        "blockedByDraft unknown/unavailable -> unknown automatic issue_source_unavailable retryable",
        "blockedByDraft unknown/reportedMissing -> unknown automatic issue_source_unavailable retryable",
        "blockedByDraft unknown/original -> unknown automatic issue_waiting_original retryable",
        "blockedByDraft unknown/originalEN -> unknown automatic issue_waiting_original retryable",
        "blockedByDraft unknown/originalDE -> unknown automatic issue_waiting_original retryable",
        "blockedByDraft none -> remoteDraft automatic issue_remote_draft retryable",
        "blockedByDraft plain-text -> remoteDraft automatic issue_remote_draft retryable",
        "blockedByDraft damaged-record -> unknown automatic issue_unknown_waiting retryable",
        "failed network -> network userResolvable issue_network retryable",
        "failed deviceStorage -> deviceStorage userResolvable issue_device_storage retryable",
        "failed remoteDraft -> remoteDraft userResolvable issue_remote_draft retryable",
        "failed remoteDraftStale -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "failed sourceMissing -> sourceMissing permanent issue_source_missing permanent",
        "failed permission -> permission userResolvable issue_permission notRetryable",
        "failed unsupported -> unsupported permanent issue_unsupported permanent",
        "failed remoteService -> remoteService userResolvable issue_remote_service retryable",
        "failed localState -> localState userResolvable error_local_state_unavailable retryable",
        "failed remoteDeletion -> remoteDeletion decision state_skipped_remote_deletion notRetryable",
        "failed deletedElsewhere -> deletedElsewhere decision issue_deleted_elsewhere notRetryable",
        "failed accountStorage -> accountStorage userResolvable issue_account_storage retryable",
        "failed unknown -> unknown userResolvable fail_reason_generic retryable",
        "failed unknown/notReady -> unknown automatic issue_source_not_ready retryable",
        "failed unknown/unavailable -> unknown automatic issue_source_unavailable retryable",
        "failed unknown/reportedMissing -> unknown automatic issue_source_unavailable retryable",
        "failed unknown/original -> unknown automatic issue_waiting_original retryable",
        "failed unknown/originalEN -> unknown automatic issue_waiting_original retryable",
        "failed unknown/originalDE -> unknown automatic issue_waiting_original retryable",
        "failed none -> unknown userResolvable fail_reason_generic retryable",
        "failed plain-text -> unknown userResolvable fail_reason_generic retryable",
        "failed damaged-record -> unknown userResolvable fail_reason_generic retryable",
        "failedPermanent network -> network permanent issue_permanent permanent",
        "failedPermanent deviceStorage -> deviceStorage permanent issue_permanent permanent",
        "failedPermanent remoteDraft -> remoteDraft permanent issue_permanent permanent",
        "failedPermanent remoteDraftStale -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "failedPermanent sourceMissing -> sourceMissing permanent issue_source_missing permanent",
        "failedPermanent permission -> permission permanent issue_permanent permanent",
        "failedPermanent unsupported -> unsupported permanent issue_unsupported permanent",
        "failedPermanent remoteService -> remoteService permanent issue_permanent permanent",
        "failedPermanent localState -> localState permanent issue_permanent permanent",
        "failedPermanent remoteDeletion -> remoteDeletion permanent issue_permanent permanent",
        "failedPermanent deletedElsewhere -> deletedElsewhere decision issue_deleted_elsewhere permanent",
        "failedPermanent accountStorage -> accountStorage permanent issue_permanent permanent",
        "failedPermanent unknown -> unknown permanent issue_permanent permanent",
        "failedPermanent unknown/notReady -> unknown permanent issue_permanent permanent",
        "failedPermanent unknown/unavailable -> unknown permanent issue_permanent permanent",
        "failedPermanent unknown/reportedMissing -> unknown permanent issue_permanent permanent",
        "failedPermanent unknown/original -> unknown permanent issue_permanent permanent",
        "failedPermanent unknown/originalEN -> unknown permanent issue_permanent permanent",
        "failedPermanent unknown/originalDE -> unknown permanent issue_permanent permanent",
        "failedPermanent none -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "failedPermanent plain-text -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "failedPermanent damaged-record -> unknown permanent issue_permanent permanent",
        "sourceMissing network -> network permanent issue_permanent permanent",
        "sourceMissing deviceStorage -> deviceStorage permanent issue_permanent permanent",
        "sourceMissing remoteDraft -> remoteDraft permanent issue_permanent permanent",
        "sourceMissing remoteDraftStale -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "sourceMissing sourceMissing -> sourceMissing permanent issue_source_missing permanent",
        "sourceMissing permission -> permission permanent issue_permanent permanent",
        "sourceMissing unsupported -> unsupported permanent issue_unsupported permanent",
        "sourceMissing remoteService -> remoteService permanent issue_permanent permanent",
        "sourceMissing localState -> localState permanent issue_permanent permanent",
        "sourceMissing remoteDeletion -> remoteDeletion permanent issue_permanent permanent",
        "sourceMissing deletedElsewhere -> deletedElsewhere decision issue_deleted_elsewhere permanent",
        "sourceMissing accountStorage -> accountStorage permanent issue_permanent permanent",
        "sourceMissing unknown -> unknown permanent issue_permanent permanent",
        "sourceMissing unknown/notReady -> unknown permanent issue_permanent permanent",
        "sourceMissing unknown/unavailable -> unknown permanent issue_permanent permanent",
        "sourceMissing unknown/reportedMissing -> unknown permanent issue_permanent permanent",
        "sourceMissing unknown/original -> unknown permanent issue_permanent permanent",
        "sourceMissing unknown/originalEN -> unknown permanent issue_permanent permanent",
        "sourceMissing unknown/originalDE -> unknown permanent issue_permanent permanent",
        "sourceMissing none -> sourceMissing permanent issue_source_missing permanent",
        "sourceMissing plain-text -> sourceMissing permanent issue_source_missing permanent",
        "sourceMissing damaged-record -> unknown permanent issue_permanent permanent",
        "skippedRemoteDeletion network -> network automatic issue_network retryable",
        "skippedRemoteDeletion deviceStorage -> deviceStorage automatic issue_device_storage retryable",
        "skippedRemoteDeletion remoteDraft -> remoteDraft automatic issue_remote_draft retryable",
        "skippedRemoteDeletion remoteDraftStale -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "skippedRemoteDeletion sourceMissing -> sourceMissing permanent issue_source_missing permanent",
        "skippedRemoteDeletion permission -> permission userResolvable issue_permission notRetryable",
        "skippedRemoteDeletion unsupported -> unsupported permanent issue_unsupported permanent",
        "skippedRemoteDeletion remoteService -> remoteService automatic issue_remote_service retryable",
        "skippedRemoteDeletion localState -> localState userResolvable error_local_state_unavailable retryable",
        "skippedRemoteDeletion remoteDeletion -> remoteDeletion decision state_skipped_remote_deletion notRetryable",
        "skippedRemoteDeletion deletedElsewhere -> deletedElsewhere decision issue_deleted_elsewhere notRetryable",
        "skippedRemoteDeletion accountStorage -> accountStorage userResolvable issue_account_storage retryable",
        "skippedRemoteDeletion unknown -> unknown automatic issue_unknown_waiting retryable",
        "skippedRemoteDeletion unknown/notReady -> unknown automatic issue_source_not_ready retryable",
        "skippedRemoteDeletion unknown/unavailable -> unknown automatic issue_source_unavailable retryable",
        "skippedRemoteDeletion unknown/reportedMissing -> unknown automatic issue_source_unavailable retryable",
        "skippedRemoteDeletion unknown/original -> unknown automatic issue_waiting_original retryable",
        "skippedRemoteDeletion unknown/originalEN -> unknown automatic issue_waiting_original retryable",
        "skippedRemoteDeletion unknown/originalDE -> unknown automatic issue_waiting_original retryable",
        "skippedRemoteDeletion none -> remoteDeletion decision state_skipped_remote_deletion notRetryable",
        "skippedRemoteDeletion plain-text -> remoteDeletion decision state_skipped_remote_deletion notRetryable",
        "skippedRemoteDeletion damaged-record -> unknown automatic issue_unknown_waiting retryable",
    ]
}
