import Foundation
import PhotosCore
import Testing

@testable import UploadCore

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

    private static let refusalStart = Date(timeIntervalSince1970: 1_790_000_000)

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
            (
                "remoteService/temporary",
                BackupIssueRecord(kind: .remoteService, detail: "PRIVATE DETAIL", automaticRetryAttempt: 1)
                    .persistedValue
            ),
            (
                "remoteService/refused",
                BackupIssueRecord(
                    kind: .remoteService, detail: "PRIVATE DETAIL",
                    serviceRejection: .init(rounds: 1, firstRoundAt: refusalStart, lastRoundAt: refusalStart)
                ).persistedValue
            ),
            (
                "remoteService/stopped",
                BackupIssueRecord(
                    kind: .remoteService, detail: "PRIVATE DETAIL",
                    serviceRejection: .init(
                        rounds: 3, firstRoundAt: refusalStart, lastRoundAt: refusalStart.addingTimeInterval(72 * 3600))
                ).persistedValue
            ),
        ]
        + [
            ("none", nil),
            ("plain-text", "PRIVATE SERVER TEXT"),
            ("damaged-record", BackupIssueRecord.storagePrefix + "not base64"),
        ]

    private static let reasonKeys = [
        "issue_network", "issue_device_storage", "issue_remote_draft", "issue_remote_draft_stale",
        "issue_source_missing", "issue_permission", "issue_unsupported", "issue_remote_service",
        "error_local_state_unavailable", "state_skipped_remote_deletion", "issue_deleted_elsewhere",
        "issue_account_storage", "fail_reason_generic", "issue_waiting_original",
        "issue_service_rejected", "issue_after_several_tries",
        "issue_source_unavailable", "issue_source_not_ready", "issue_unknown_waiting",
    ]

    private static func describe(state: UploadBackupSyncQueueState, lastError: String?) -> String {
        let item = Self.item(state: state, lastError: lastError)
        let key = reasonKeys.first { L10n.string(dynamicKey: "backup." + $0) == item.reason } ?? "UNMAPPED"
        let retry = item.isPermanent ? "permanent" : item.isRetryable ? "retryable" : "notRetryable"
        #expect(!item.isPermanent || !item.isRetryable)
        return "\(item.issue.rawValue) \(item.category.rawValue) \(key) \(retry)"
    }

    /// The list section of a stored row, and whether it counts toward the attention line.
    private static func placement(state: UploadBackupSyncQueueState, lastError: String?) -> String {
        let outcome = BackupItemOutcome(state: state, record: BackupIssueRecord.decode(lastError))
        #expect(Self.item(state: state, lastError: lastError).section == outcome.section)
        return "\(outcome.section.rawValue) \(outcome.raisesAttention ? "attention" : "calm")"
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
                "\(state.rawValue) \(reason.label) -> \(Self.describe(state: state, lastError: reason.lastError))"
            }
        }
        #expect(actual == Self.storedRowOutcomes)
    }

    @Test func everyStoredRowKeepsItsSection() {
        let actual = Self.distinctStates.flatMap { state in
            Self.storedReasons.map { reason in
                "\(state.rawValue) \(reason.label) -> \(Self.placement(state: state, lastError: reason.lastError))"
            }
        }
        #expect(actual == Self.storedRowSections)
    }

    @Test(arguments: UploadBackupSyncQueueState.allCases.filter { !distinctStates.contains($0) })
    func everyOtherStateKeepsTheOutcomeOfAWaitingRow(state: UploadBackupSyncQueueState) {
        for reason in Self.storedReasons {
            #expect(
                Self.describe(state: state, lastError: reason.lastError)
                    == Self.describe(state: .discovered, lastError: reason.lastError), "\(reason.label)")
            #expect(
                Self.placement(state: state, lastError: reason.lastError)
                    == Self.placement(state: .discovered, lastError: reason.lastError), "\(reason.label)")
        }
    }

    /// The runner stores these details in the queue, and the outcome reads them back: their values are a stored format.
    /// The original-wait check also knows the two sentences that builds before the key stored.
    @Test func theStoredWaitDetailsKeepTheirValues() {
        #expect(BackupItemOutcome.sourceUnavailableDetail == "backup.issue_source_unavailable")
        #expect(BackupItemOutcome.sourceReportedMissingDetail == "backup.issue_source_unavailable.reported_missing")
        #expect(BackupItemOutcome.sourceNotReadyDetail == "error.upload_source_not_ready")
        #expect(BackupItemOutcome.isWaitingForPhotos("backup.issue_source_unavailable"))
        #expect(BackupItemOutcome.isWaitingForPhotos("backup.issue_source_unavailable.reported_missing"))
        #expect(!BackupItemOutcome.isWaitingForPhotos("error.upload_source_not_ready"))
        #expect(!BackupItemOutcome.isWaitingForPhotos(nil))
        for stored in [
            "backup.issue_waiting_original",
            "The edited photo is waiting for its original resources. Backup will retry automatically.",
            "Das bearbeitete Foto wartet auf seine Originalressourcen. Das Backup versucht es automatisch erneut.",
        ] {
            #expect(BackupItemOutcome.isWaitingForOriginal(stored), "\(stored)")
        }
        #expect(!BackupItemOutcome.isWaitingForOriginal("backup.issue_source_unavailable"))
        #expect(!BackupItemOutcome.isWaitingForOriginal(nil))
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
        "discovered remoteService -> remoteService automatic issue_unknown_waiting retryable",
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
        "discovered remoteService/temporary -> remoteService automatic issue_remote_service retryable",
        "discovered remoteService/refused -> remoteService automatic issue_unknown_waiting retryable",
        "discovered remoteService/stopped -> remoteService automatic issue_unknown_waiting retryable",
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
        "blockedByDraft remoteService -> remoteService automatic issue_unknown_waiting retryable",
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
        "blockedByDraft remoteService/temporary -> remoteService automatic issue_remote_service retryable",
        "blockedByDraft remoteService/refused -> remoteService automatic issue_unknown_waiting retryable",
        "blockedByDraft remoteService/stopped -> remoteService automatic issue_unknown_waiting retryable",
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
        "failed remoteService -> remoteService userResolvable issue_after_several_tries retryable",
        "failed localState -> localState userResolvable error_local_state_unavailable retryable",
        "failed remoteDeletion -> remoteDeletion decision state_skipped_remote_deletion notRetryable",
        "failed deletedElsewhere -> deletedElsewhere decision issue_deleted_elsewhere notRetryable",
        "failed accountStorage -> accountStorage userResolvable issue_account_storage retryable",
        "failed unknown -> unknown userResolvable issue_after_several_tries retryable",
        "failed unknown/notReady -> unknown automatic issue_source_not_ready retryable",
        "failed unknown/unavailable -> unknown automatic issue_source_unavailable retryable",
        "failed unknown/reportedMissing -> unknown automatic issue_source_unavailable retryable",
        "failed unknown/original -> unknown automatic issue_waiting_original retryable",
        "failed unknown/originalEN -> unknown automatic issue_waiting_original retryable",
        "failed unknown/originalDE -> unknown automatic issue_waiting_original retryable",
        "failed remoteService/temporary -> remoteService userResolvable issue_after_several_tries retryable",
        "failed remoteService/refused -> remoteService userResolvable issue_after_several_tries retryable",
        "failed remoteService/stopped -> remoteService userResolvable issue_after_several_tries retryable",
        "failed none -> unknown userResolvable issue_after_several_tries retryable",
        "failed plain-text -> unknown userResolvable issue_after_several_tries retryable",
        "failed damaged-record -> unknown userResolvable issue_after_several_tries retryable",
        "failedPermanent network -> network permanent issue_after_several_tries permanent",
        "failedPermanent deviceStorage -> deviceStorage permanent issue_after_several_tries permanent",
        "failedPermanent remoteDraft -> remoteDraft permanent issue_after_several_tries permanent",
        "failedPermanent remoteDraftStale -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "failedPermanent sourceMissing -> sourceMissing permanent issue_source_missing permanent",
        "failedPermanent permission -> permission permanent issue_after_several_tries permanent",
        "failedPermanent unsupported -> unsupported permanent issue_unsupported permanent",
        "failedPermanent remoteService -> remoteService permanent issue_after_several_tries permanent",
        "failedPermanent localState -> localState permanent issue_after_several_tries permanent",
        "failedPermanent remoteDeletion -> remoteDeletion permanent issue_after_several_tries permanent",
        "failedPermanent deletedElsewhere -> deletedElsewhere decision issue_deleted_elsewhere permanent",
        "failedPermanent accountStorage -> accountStorage permanent issue_after_several_tries permanent",
        "failedPermanent unknown -> unknown permanent issue_after_several_tries permanent",
        "failedPermanent unknown/notReady -> unknown permanent issue_after_several_tries permanent",
        "failedPermanent unknown/unavailable -> unknown permanent issue_after_several_tries permanent",
        "failedPermanent unknown/reportedMissing -> unknown permanent issue_after_several_tries permanent",
        "failedPermanent unknown/original -> unknown permanent issue_after_several_tries permanent",
        "failedPermanent unknown/originalEN -> unknown permanent issue_after_several_tries permanent",
        "failedPermanent unknown/originalDE -> unknown permanent issue_after_several_tries permanent",
        "failedPermanent remoteService/temporary -> remoteService permanent issue_after_several_tries permanent",
        "failedPermanent remoteService/refused -> remoteService permanent issue_after_several_tries permanent",
        "failedPermanent remoteService/stopped -> remoteService permanent issue_service_rejected permanent",
        "failedPermanent none -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "failedPermanent plain-text -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "failedPermanent damaged-record -> unknown permanent issue_after_several_tries permanent",
        "sourceMissing network -> network permanent issue_after_several_tries permanent",
        "sourceMissing deviceStorage -> deviceStorage permanent issue_after_several_tries permanent",
        "sourceMissing remoteDraft -> remoteDraft permanent issue_after_several_tries permanent",
        "sourceMissing remoteDraftStale -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "sourceMissing sourceMissing -> sourceMissing permanent issue_source_missing permanent",
        "sourceMissing permission -> permission permanent issue_after_several_tries permanent",
        "sourceMissing unsupported -> unsupported permanent issue_unsupported permanent",
        "sourceMissing remoteService -> remoteService permanent issue_after_several_tries permanent",
        "sourceMissing localState -> localState permanent issue_after_several_tries permanent",
        "sourceMissing remoteDeletion -> remoteDeletion permanent issue_after_several_tries permanent",
        "sourceMissing deletedElsewhere -> deletedElsewhere decision issue_deleted_elsewhere permanent",
        "sourceMissing accountStorage -> accountStorage permanent issue_after_several_tries permanent",
        "sourceMissing unknown -> unknown permanent issue_after_several_tries permanent",
        "sourceMissing unknown/notReady -> unknown permanent issue_after_several_tries permanent",
        "sourceMissing unknown/unavailable -> unknown permanent issue_after_several_tries permanent",
        "sourceMissing unknown/reportedMissing -> unknown permanent issue_after_several_tries permanent",
        "sourceMissing unknown/original -> unknown permanent issue_after_several_tries permanent",
        "sourceMissing unknown/originalEN -> unknown permanent issue_after_several_tries permanent",
        "sourceMissing unknown/originalDE -> unknown permanent issue_after_several_tries permanent",
        "sourceMissing remoteService/temporary -> remoteService permanent issue_after_several_tries permanent",
        "sourceMissing remoteService/refused -> remoteService permanent issue_after_several_tries permanent",
        "sourceMissing remoteService/stopped -> remoteService permanent issue_after_several_tries permanent",
        "sourceMissing none -> sourceMissing permanent issue_source_missing permanent",
        "sourceMissing plain-text -> sourceMissing permanent issue_source_missing permanent",
        "sourceMissing damaged-record -> unknown permanent issue_after_several_tries permanent",
        "skippedRemoteDeletion network -> network automatic issue_network retryable",
        "skippedRemoteDeletion deviceStorage -> deviceStorage automatic issue_device_storage retryable",
        "skippedRemoteDeletion remoteDraft -> remoteDraft automatic issue_remote_draft retryable",
        "skippedRemoteDeletion remoteDraftStale -> remoteDraftStale permanent issue_remote_draft_stale permanent",
        "skippedRemoteDeletion sourceMissing -> sourceMissing permanent issue_source_missing permanent",
        "skippedRemoteDeletion permission -> permission userResolvable issue_permission notRetryable",
        "skippedRemoteDeletion unsupported -> unsupported permanent issue_unsupported permanent",
        "skippedRemoteDeletion remoteService -> remoteService automatic issue_unknown_waiting retryable",
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
        "skippedRemoteDeletion remoteService/temporary -> remoteService automatic issue_remote_service retryable",
        "skippedRemoteDeletion remoteService/refused -> remoteService automatic issue_unknown_waiting retryable",
        "skippedRemoteDeletion remoteService/stopped -> remoteService automatic issue_unknown_waiting retryable",
        "skippedRemoteDeletion none -> remoteDeletion decision state_skipped_remote_deletion notRetryable",
        "skippedRemoteDeletion plain-text -> remoteDeletion decision state_skipped_remote_deletion notRetryable",
        "skippedRemoteDeletion damaged-record -> unknown automatic issue_unknown_waiting retryable",
    ]

    private static let storedRowSections = [
        "discovered network -> continuesByItself calm",
        "discovered deviceStorage -> continuesByItself calm",
        "discovered remoteDraft -> continuesByItself calm",
        "discovered remoteDraftStale -> notPossible calm",
        "discovered sourceMissing -> notPossible calm",
        "discovered permission -> actionNeeded calm",
        "discovered unsupported -> notPossible calm",
        "discovered remoteService -> continuesByItself calm",
        "discovered localState -> continuesByItself calm",
        "discovered remoteDeletion -> actionNeeded calm",
        "discovered deletedElsewhere -> actionNeeded calm",
        "discovered accountStorage -> actionNeeded calm",
        "discovered unknown -> continuesByItself calm",
        "discovered unknown/notReady -> continuesByItself calm",
        "discovered unknown/unavailable -> continuesByItself calm",
        "discovered unknown/reportedMissing -> continuesByItself calm",
        "discovered unknown/original -> continuesByItself calm",
        "discovered unknown/originalEN -> continuesByItself calm",
        "discovered unknown/originalDE -> continuesByItself calm",
        "discovered remoteService/temporary -> continuesByItself calm",
        "discovered remoteService/refused -> continuesByItself calm",
        "discovered remoteService/stopped -> continuesByItself calm",
        "discovered none -> continuesByItself calm",
        "discovered plain-text -> continuesByItself calm",
        "discovered damaged-record -> continuesByItself calm",
        "blockedByDraft network -> continuesByItself calm",
        "blockedByDraft deviceStorage -> continuesByItself calm",
        "blockedByDraft remoteDraft -> continuesByItself calm",
        "blockedByDraft remoteDraftStale -> notPossible calm",
        "blockedByDraft sourceMissing -> notPossible calm",
        "blockedByDraft permission -> actionNeeded calm",
        "blockedByDraft unsupported -> notPossible calm",
        "blockedByDraft remoteService -> continuesByItself calm",
        "blockedByDraft localState -> continuesByItself calm",
        "blockedByDraft remoteDeletion -> actionNeeded calm",
        "blockedByDraft deletedElsewhere -> actionNeeded calm",
        "blockedByDraft accountStorage -> actionNeeded calm",
        "blockedByDraft unknown -> continuesByItself calm",
        "blockedByDraft unknown/notReady -> continuesByItself calm",
        "blockedByDraft unknown/unavailable -> continuesByItself calm",
        "blockedByDraft unknown/reportedMissing -> continuesByItself calm",
        "blockedByDraft unknown/original -> continuesByItself calm",
        "blockedByDraft unknown/originalEN -> continuesByItself calm",
        "blockedByDraft unknown/originalDE -> continuesByItself calm",
        "blockedByDraft remoteService/temporary -> continuesByItself calm",
        "blockedByDraft remoteService/refused -> continuesByItself calm",
        "blockedByDraft remoteService/stopped -> continuesByItself calm",
        "blockedByDraft none -> continuesByItself calm",
        "blockedByDraft plain-text -> continuesByItself calm",
        "blockedByDraft damaged-record -> continuesByItself calm",
        "failed network -> continuesByItself calm",
        "failed deviceStorage -> continuesByItself calm",
        "failed remoteDraft -> continuesByItself calm",
        "failed remoteDraftStale -> notPossible calm",
        "failed sourceMissing -> notPossible calm",
        "failed permission -> actionNeeded attention",
        "failed unsupported -> notPossible calm",
        "failed remoteService -> continuesByItself calm",
        "failed localState -> continuesByItself calm",
        "failed remoteDeletion -> actionNeeded attention",
        "failed deletedElsewhere -> actionNeeded attention",
        "failed accountStorage -> actionNeeded attention",
        "failed unknown -> continuesByItself calm",
        "failed unknown/notReady -> continuesByItself calm",
        "failed unknown/unavailable -> continuesByItself calm",
        "failed unknown/reportedMissing -> continuesByItself calm",
        "failed unknown/original -> continuesByItself calm",
        "failed unknown/originalEN -> continuesByItself calm",
        "failed unknown/originalDE -> continuesByItself calm",
        "failed remoteService/temporary -> continuesByItself calm",
        "failed remoteService/refused -> continuesByItself calm",
        "failed remoteService/stopped -> continuesByItself calm",
        "failed none -> continuesByItself calm",
        "failed plain-text -> continuesByItself calm",
        "failed damaged-record -> continuesByItself calm",
        "failedPermanent network -> notPossible calm",
        "failedPermanent deviceStorage -> notPossible calm",
        "failedPermanent remoteDraft -> notPossible calm",
        "failedPermanent remoteDraftStale -> notPossible calm",
        "failedPermanent sourceMissing -> notPossible calm",
        "failedPermanent permission -> notPossible calm",
        "failedPermanent unsupported -> notPossible calm",
        "failedPermanent remoteService -> notPossible calm",
        "failedPermanent localState -> notPossible calm",
        "failedPermanent remoteDeletion -> notPossible calm",
        "failedPermanent deletedElsewhere -> actionNeeded attention",
        "failedPermanent accountStorage -> notPossible calm",
        "failedPermanent unknown -> notPossible calm",
        "failedPermanent unknown/notReady -> notPossible calm",
        "failedPermanent unknown/unavailable -> notPossible calm",
        "failedPermanent unknown/reportedMissing -> notPossible calm",
        "failedPermanent unknown/original -> notPossible calm",
        "failedPermanent unknown/originalEN -> notPossible calm",
        "failedPermanent unknown/originalDE -> notPossible calm",
        "failedPermanent remoteService/temporary -> notPossible calm",
        "failedPermanent remoteService/refused -> notPossible calm",
        "failedPermanent remoteService/stopped -> notPossible calm",
        "failedPermanent none -> notPossible calm",
        "failedPermanent plain-text -> notPossible calm",
        "failedPermanent damaged-record -> notPossible calm",
        "sourceMissing network -> notPossible calm",
        "sourceMissing deviceStorage -> notPossible calm",
        "sourceMissing remoteDraft -> notPossible calm",
        "sourceMissing remoteDraftStale -> notPossible calm",
        "sourceMissing sourceMissing -> notPossible calm",
        "sourceMissing permission -> notPossible calm",
        "sourceMissing unsupported -> notPossible calm",
        "sourceMissing remoteService -> notPossible calm",
        "sourceMissing localState -> notPossible calm",
        "sourceMissing remoteDeletion -> notPossible calm",
        "sourceMissing deletedElsewhere -> actionNeeded attention",
        "sourceMissing accountStorage -> notPossible calm",
        "sourceMissing unknown -> notPossible calm",
        "sourceMissing unknown/notReady -> notPossible calm",
        "sourceMissing unknown/unavailable -> notPossible calm",
        "sourceMissing unknown/reportedMissing -> notPossible calm",
        "sourceMissing unknown/original -> notPossible calm",
        "sourceMissing unknown/originalEN -> notPossible calm",
        "sourceMissing unknown/originalDE -> notPossible calm",
        "sourceMissing remoteService/temporary -> notPossible calm",
        "sourceMissing remoteService/refused -> notPossible calm",
        "sourceMissing remoteService/stopped -> notPossible calm",
        "sourceMissing none -> notPossible calm",
        "sourceMissing plain-text -> notPossible calm",
        "sourceMissing damaged-record -> notPossible calm",
        "skippedRemoteDeletion network -> continuesByItself calm",
        "skippedRemoteDeletion deviceStorage -> continuesByItself calm",
        "skippedRemoteDeletion remoteDraft -> continuesByItself calm",
        "skippedRemoteDeletion remoteDraftStale -> notPossible calm",
        "skippedRemoteDeletion sourceMissing -> notPossible calm",
        "skippedRemoteDeletion permission -> actionNeeded calm",
        "skippedRemoteDeletion unsupported -> notPossible calm",
        "skippedRemoteDeletion remoteService -> continuesByItself calm",
        "skippedRemoteDeletion localState -> continuesByItself calm",
        "skippedRemoteDeletion remoteDeletion -> actionNeeded calm",
        "skippedRemoteDeletion deletedElsewhere -> actionNeeded calm",
        "skippedRemoteDeletion accountStorage -> actionNeeded calm",
        "skippedRemoteDeletion unknown -> continuesByItself calm",
        "skippedRemoteDeletion unknown/notReady -> continuesByItself calm",
        "skippedRemoteDeletion unknown/unavailable -> continuesByItself calm",
        "skippedRemoteDeletion unknown/reportedMissing -> continuesByItself calm",
        "skippedRemoteDeletion unknown/original -> continuesByItself calm",
        "skippedRemoteDeletion unknown/originalEN -> continuesByItself calm",
        "skippedRemoteDeletion unknown/originalDE -> continuesByItself calm",
        "skippedRemoteDeletion remoteService/temporary -> continuesByItself calm",
        "skippedRemoteDeletion remoteService/refused -> continuesByItself calm",
        "skippedRemoteDeletion remoteService/stopped -> continuesByItself calm",
        "skippedRemoteDeletion none -> actionNeeded calm",
        "skippedRemoteDeletion plain-text -> actionNeeded calm",
        "skippedRemoteDeletion damaged-record -> continuesByItself calm",
    ]
}
