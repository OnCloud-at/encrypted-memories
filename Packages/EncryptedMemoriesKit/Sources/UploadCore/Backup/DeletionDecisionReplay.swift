import Foundation
import PhotosCore

/// The exact revisions covered by one recorded choice. It shares the choice's journal line.
public struct DeletionDecisionIntent: Sendable, Equatable, Codable {
    public let id: UUID
    public let revisions: [UploadBackupRevision]

    public init(id: UUID = UUID(), revisions: [UploadBackupRevision]) {
        self.id = id
        self.revisions = Set(revisions).sorted()
    }
}

/// Scalar columns for one revision of a decision, independent of the journal's file format.
public struct DeletionDecisionRow: Sendable, Equatable {
    public enum Choice: String, Sendable { case keepDeleted, backUpAgain }

    public let decisionID: UUID
    public let sourceKind: UploadSourceIdentity.Kind
    public let sourceID: String
    public let resource: String
    public let choice: Choice
    public let reopenedRevision: Int64?
    public let revision: Int64

    public var source: UploadSourceIdentity {
        UploadSourceIdentity(kind: sourceKind, identifier: sourceID, resource: .init(rawValue: resource))
    }

    /// Converts one decoded line without accessing a store. Malformed intents remain unreadable, never absent.
    public static func rows(key: String, entry: EditReplacementJournalEntry) throws -> [Self] {
        guard let intent = entry.deletionDecision else { return [] }
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3, let kind = UploadSourceIdentity.Kind(rawValue: String(parts[0])),
            let resource = parts.last, !resource.isEmpty, !intent.revisions.isEmpty,
            (entry.keptDeleted == true) != (entry.backUpAgainRevision != nil),
            entry.backUpAgainRevision.map({ intent.revisions.contains($0) }) ?? true
        else { throw UploadError.backend(L10n.string("backup.error_local_state_unavailable")) }
        return intent.revisions.map {
            Self(
                decisionID: intent.id, sourceKind: kind,
                sourceID: parts.dropFirst().dropLast().joined(separator: "|"), resource: String(resource),
                choice: entry.keptDeleted == true ? .keepDeleted : .backUpAgain,
                reopenedRevision: entry.backUpAgainRevision?.rawValue, revision: $0.rawValue)
        }
    }

    /// The decision and its replay use the same target states and existing localized reason.
    public var update: UploadBackupSyncQueueManifestStore.StateUpdate {
        UploadBackupSyncQueueManifestStore.StateUpdate(
            revision: .init(rawValue: revision),
            state: choice == .keepDeleted
                ? .skippedRemoteDeletion
                : revision == reopenedRevision ? .discovered : .dismissedFailure,
            lastError: choice == .keepDeleted
                ? BackupIssueRecord(
                    kind: .remoteDeletion, detail: L10n.string("backup.state_skipped_remote_deletion")
                ).persistedValue : nil)
    }
}

/// The file-backed intent log. A database can later supply the same decision rows.
public protocol DeletionDecisionLog: Sendable {
    @discardableResult
    func recordDeletionDecision(
        _ choice: EditReplacementDeletionChoice, revisions: [UploadBackupRevision], for source: UploadSourceIdentity
    ) throws -> DeletionDecisionIntent
    /// One lookup per pending key; an unreadable intent must not hide another key.
    func pendingDeletionDecisionSources() -> [StoreLookup<UploadSourceIdentity>]
    func pendingDeletionDecision(for source: UploadSourceIdentity) throws -> [DeletionDecisionRow]
    func settleDeletionDecision(id: UUID, for source: UploadSourceIdentity) throws
}

public enum DeletionDecisionReplay {
    /// Records the intent before the queue transaction. A failed read of the recorded rows or a failed transaction
    /// takes both intent and choice back and throws the local-state error.
    @MainActor
    public static func record(
        _ choice: EditReplacementDeletionChoice, revisions: [UploadBackupRevision], for source: UploadSourceIdentity,
        queue: UploadBackupSyncQueueManifestStore, journal: any EditReplacementJournaling, at date: Date,
        log: BackgroundWorkLog = .system
    ) throws {
        let previous = journal.entry(for: source).deletionChoice
        let intent = try PhotoPerformanceSignposts.database.interval("BackupDecisionJournal") {
            try journal.recordDeletionDecision(choice, revisions: revisions, for: source)
        }
        var written = choice
        written.deletionDecision = intent
        do {
            let rows = try journal.pendingDeletionDecision(for: source)
            guard
                PhotoPerformanceSignposts.database.interval(
                    "BackupDecisionQueueWrite", { queue.updateStates(of: source, rows.map(\.update), updatedAt: date) })
            else { throw UploadError.backend(L10n.string("backup.error_local_state_unavailable")) }
        } catch {
            do { try journal.restoreDeletionChoice(previous, ifStill: written, for: source) } catch {
                log.notice(
                    .photoBackup, "decision.choiceNotRestored",
                    [(.init("choice"), .word(choice.keptDeleted == true ? "keepDeleted" : "backUpAgain"))])
            }
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }
        // A failed settle only costs another idempotent replay; the queue already holds the complete choice.
        try? journal.settleDeletionDecision(id: intent.id, for: source)
    }

    /// One intent has no suspension point. Unknown reads or failed writes retain the whole intent for retry. A store
    /// with a recorded failure still accepts writes, but its reads may miss a parked row; the intent would then settle
    /// without its queue write, so such a store keeps the intent.
    @MainActor
    public static func apply(
        _ rows: [DeletionDecisionRow], queue: UploadBackupSyncQueueManifestStore,
        journal: any DeletionDecisionLog, at date: Date
    ) throws {
        guard let first = rows.first else { return }
        guard queue.isOperational() else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }
        guard rows.allSatisfy({ $0.source == first.source && $0.decisionID == first.decisionID }) else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }
        var updates: [UploadBackupSyncQueueManifestStore.StateUpdate] = []
        for row in rows {
            guard let current = try queue.entry(for: row.source, revision: .init(rawValue: row.revision)) else {
                continue
            }
            guard current.state == .failedPermanent,
                BackupIssueRecord.decode(current.lastError)?.kind == .deletedElsewhere
            else { continue }
            updates.append(row.update)
        }
        guard queue.updateStates(of: first.source, updates, updatedAt: date) else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }
        try journal.settleDeletionDecision(id: first.decisionID, for: first.source)
    }

    /// Replays each pending key independently, retaining unreadable intents and intents whose apply failed, for example
    /// on a store with a recorded failure. Cancellation or `shouldStop` stops between atomic sources, as in the
    /// thumbnail coverage refresh. With no intent the pending index avoids scanning historical entries.
    @MainActor
    public static func run(
        queue: UploadBackupSyncQueueManifestStore, journal: any DeletionDecisionLog, at date: Date,
        log: BackgroundWorkLog = .system, shouldStop: @MainActor () -> Bool = { false }
    ) async -> Bool {
        var complete = true
        for lookup in journal.pendingDeletionDecisionSources() {
            guard !Task.isCancelled, !shouldStop() else { return false }
            switch lookup {
            case .found(let source):
                do {
                    try apply(
                        try journal.pendingDeletionDecision(for: source), queue: queue, journal: journal, at: date)
                } catch {
                    complete = false
                    log.notice(.photoBackup, "decision.replayKept", [(.init("reason"), .word("notApplied"))])
                }
            // The file store lists only keys whose entry holds an intent, so it never answers absent here.
            case .unknown, .absent:
                complete = false
                log.notice(.photoBackup, "decision.replayKept", [(.init("reason"), .word("unreadable"))])
            }
            await Task.yield()
        }
        return complete
    }
}
