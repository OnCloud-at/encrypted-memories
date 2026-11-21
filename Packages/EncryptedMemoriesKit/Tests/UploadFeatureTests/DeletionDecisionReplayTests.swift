import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

extension DeletionDecisionLog {
    /// Strict aggregation for assertions that inspect every pending row.
    func pendingDeletionDecisions() throws -> [DeletionDecisionRow] {
        try pendingDeletionDecisionSources().flatMap { lookup in
            guard case .found(let source) = lookup else { throw UploadError.backend("unreadable intent") }
            return try pendingDeletionDecision(for: source)
        }
    }
}

extension EditReplacementJournaling {
    /// A completed keep choice for pipeline fixtures that have no queue.
    func recordKeptDeletionForFixture(for source: UploadSourceIdentity) throws {
        let intent = try recordDeletionDecision(.keptDeleted, revisions: [.init(rawValue: 1)], for: source)
        try settleDeletionDecision(id: intent.id, for: source)
    }
}

/// The edit replacement journal entry as builds 1.1.0 and 1.2.0-beta.1 decode it (the same eleven fields in both).
/// Build 1.0.5 has no such journal. A line that a later build writes must decode here with the
/// choice unchanged, or an earlier build would refuse the whole journal after a downgrade.
private struct EarlierBuildEntry: Codable, Equatable {
    var superseded: [PhotoUID]
    var remoteSuperseded: [String]?
    var retired: [String]
    var uploadedEdit: Bool?
    var retireIntent: [String: [String]]?
    var proven: [String]?
    var inherited: [String: [String]]?
    var gone: [String]?
    var keptDeleted: Bool?
    var backUpAgainRevision: UploadBackupRevision?
    var deletionCheckStartedAt: Date?
}

private struct EarlierBuildLine: Codable {
    let key: String
    let entry: EarlierBuildEntry?
}

final class DeletionDecisionReplayTests: XCTestCase {
    @MainActor
    private func withWorld(_ body: (DeletionReplayWorld) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        defer { queue.close() }
        let files = StorageFaultFiles()
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory, fileSystem: files))
        let world = DeletionReplayWorld(directory: directory, queue: queue, journal: journal, files: files)
        for revision in world.revisions { XCTAssertTrue(queue.upsert(world.entry(revision))) }
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "gone"), for: world.source)
        try await body(world)
    }

    @MainActor
    func testTheChoiceAndIntentShareOneLine() async throws {
        try await withWorld { world in
            var writes = 0
            world.files.watch(failing: [2], onStart: { _ in writes += 1 })
            let intent = try world.journal.recordDeletionDecision(
                .backUpAgain(world.revisions[1]),
                revisions: Array(world.revisions.reversed()), for: world.source)
            XCTAssertEqual(writes, 1)
            let data = try Data(contentsOf: world.logURL)
            let last = try XCTUnwrap(data.split(separator: 10).last)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(last)) as? [String: Any])
            let entry = try XCTUnwrap(object["entry"] as? [String: Any])
            XCTAssertNotNil(entry["backUpAgainRevision"])
            XCTAssertNotNil(entry["deletionDecision"])
            XCTAssertEqual(world.journal.entry(for: world.source).deletionDecision, intent)
            XCTAssertEqual(intent.revisions, world.revisions)
        }
    }

    @MainActor
    func testReplayConvergesAndTheSecondRunWritesNothing() async throws {
        try await withWorld { world in
            try world.journal.recordDeletionDecision(
                .backUpAgain(world.revisions[1]),
                revisions: world.revisions, for: world.source)
            let first = await DeletionDecisionReplay.run(queue: world.queue, journal: world.journal, at: world.date)
            XCTAssertTrue(first)
            let before = try world.rows()
            XCTAssertEqual(before.map(\.state), [.dismissedFailure, .discovered])
            XCTAssertTrue(try world.journal.pendingDeletionDecisions().isEmpty)
            XCTAssertTrue(world.journal.pendingDeletionDecisionSources().isEmpty, "a settled photo leaves the index")
            let bytes = try Data(contentsOf: world.logURL)
            var statements = 0
            let fault = try SQLiteReadInterrupt(
                in: world.queue,
                matches: {
                    if $0.contains("UPDATE backup_sync_queue") { statements += 1 }
                    return false
                })
            defer { fault.stop() }
            let second = await DeletionDecisionReplay.run(
                queue: world.queue, journal: world.journal,
                at: world.date.addingTimeInterval(100))
            XCTAssertTrue(second)
            XCTAssertEqual(try world.rows(), before)
            XCTAssertEqual(try Data(contentsOf: world.logURL), bytes)
            XCTAssertEqual(statements, 0)
        }
    }

    @MainActor
    func testReplayLeavesMovedAndLaterRevisionsAlone() async throws {
        try await withWorld { world in
            try world.journal.recordDeletionDecision(.keptDeleted, revisions: world.revisions, for: world.source)
            let moved = world.entry(world.revisions[0], state: .completed)
            let later = world.entry(.init(rawValue: 3))
            XCTAssertTrue(
                world.queue.updateState(
                    source: moved.source, revision: moved.revision,
                    state: moved.state, attempts: nil, lastError: nil, updatedAt: world.date))
            XCTAssertTrue(world.queue.upsert(later))
            XCTAssertEqual(try world.queue.entry(for: moved.source, revision: moved.revision), moved)
            try DeletionDecisionReplay.apply(
                try world.journal.pendingDeletionDecision(for: world.source),
                queue: world.queue, journal: world.journal, at: world.date)
            XCTAssertEqual(try world.queue.entry(for: world.source, revision: moved.revision), moved)
            XCTAssertEqual(try world.queue.entry(for: world.source, revision: later.revision), later)
            XCTAssertEqual(try world.rows()[1].state, .skippedRemoteDeletion)
        }
    }

    /// Each of the two conditions alone keeps a row: a parked row with another reason, and a row in another state
    /// that still carries the deleted-elsewhere reason.
    @MainActor
    func testReplayChangesOnlyRowsThatStillWaitForTheQuestion() async throws {
        try await withWorld { world in
            let otherReason = UploadBackupSyncQueueEntry(
                source: world.source, revision: .init(rawValue: 3), originalFilename: "photo.heic",
                state: .failedPermanent,
                lastError: BackupIssueRecord(kind: .network, detail: "Offline").persistedValue, updatedAt: world.date)
            let otherState = UploadBackupSyncQueueEntry(
                source: world.source, revision: .init(rawValue: 4), originalFilename: "photo.heic", state: .discovered,
                lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                updatedAt: world.date)
            XCTAssertTrue(world.queue.upsert(otherReason))
            XCTAssertTrue(world.queue.upsert(otherState))
            try world.journal.recordDeletionDecision(
                .keptDeleted, revisions: world.revisions + [otherReason.revision, otherState.revision],
                for: world.source)
            try DeletionDecisionReplay.apply(
                try world.journal.pendingDeletionDecision(for: world.source),
                queue: world.queue, journal: world.journal, at: world.date)
            XCTAssertEqual(try world.queue.entry(for: world.source, revision: otherReason.revision), otherReason)
            XCTAssertEqual(try world.queue.entry(for: world.source, revision: otherState.revision), otherState)
            XCTAssertEqual(try world.rows().map(\.state), [.skippedRemoteDeletion, .skippedRemoteDeletion])
        }
    }

    /// A row of another photo does not decode, so the queue records a lasting failure. Such a store still takes writes,
    /// but its reads may miss a parked row; the replay keeps the recorded choice instead of settling it.
    @MainActor
    func testAQueueWithARecordedFailureKeepsTheChoiceForALaterStart() async throws {
        try await withWorld { world in
            let other = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "undecodable-photo")
            var otherRow = world.entry(world.revisions[0])
            otherRow.source = other
            XCTAssertTrue(world.queue.upsert(otherRow))
            var handle: OpaquePointer?
            let url = world.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)
            XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
            XCTAssertEqual(
                sqlite3_exec(
                    handle,
                    "UPDATE backup_sync_queue SET remote_commit_reconciliation=X'7B' "
                        + "WHERE source_id='undecodable-photo';", nil, nil, nil),
                SQLITE_OK)
            sqlite3_close(handle)
            XCTAssertThrowsError(try world.queue.entry(for: other, revision: otherRow.revision))
            XCTAssertFalse(world.queue.isOperational(), "the undecodable row records a lasting failure")
            try world.journal.recordDeletionDecision(.keptDeleted, revisions: world.revisions, for: world.source)
            let rows = try world.rows()
            let lines = RecordedLogLines()

            let done = await DeletionDecisionReplay.run(
                queue: world.queue, journal: world.journal, at: world.date, log: BackgroundWorkLog { lines.append($1) })

            XCTAssertFalse(done)
            XCTAssertEqual(try world.rows(), rows, "no revision changes")
            XCTAssertNotNil(
                world.journal.entry(for: world.source).deletionDecision, "the choice waits for a later start")
            XCTAssertEqual(lines.values, ["decision.replayKept reason=notApplied"])
        }
    }

    /// A choice without revisions is refused before its line is written.
    @MainActor
    func testAChoiceWithoutRevisionsWritesNoLine() async throws {
        try await withWorld { world in
            let bytes = try Data(contentsOf: world.logURL)
            let entry = world.journal.entry(for: world.source)
            XCTAssertThrowsError(
                try world.journal.recordDeletionDecision(.keptDeleted, revisions: [], for: world.source))
            XCTAssertEqual(try Data(contentsOf: world.logURL), bytes)
            XCTAssertEqual(world.journal.entry(for: world.source), entry)
            XCTAssertTrue(world.journal.pendingDeletionDecisionSources().isEmpty)
        }
    }

    /// The queue cannot read the row of the first photo, so its apply throws. The next photo is still applied, the
    /// first keeps its intent, and the replay reports that it did not finish.
    @MainActor
    func testAFailedApplyForOnePhotoDoesNotStopTheOthers() async throws {
        try await withWorld { world in
            let first = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "a-unreadable-row")
            let second = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "b-healthy-row")
            for source in [first, second] {
                var row = world.entry(world.revisions[0])
                row.source = source
                XCTAssertTrue(world.queue.upsert(row))
                try world.journal.recordDeletionDecision(.keptDeleted, revisions: [row.revision], for: source)
            }
            try world.journal.recordDeletionDecision(.keptDeleted, revisions: world.revisions, for: world.source)
            let fault = try SQLiteReadInterrupt(
                in: world.queue, matching: "SELECT original_filename, byte_count, state", occurrence: 1)

            let lines = RecordedLogLines()
            let done = await DeletionDecisionReplay.run(
                queue: world.queue, journal: world.journal, at: world.date, log: BackgroundWorkLog { lines.append($1) })
            fault.stop()

            XCTAssertTrue(fault.fired)
            XCTAssertFalse(done)
            XCTAssertEqual(lines.values, ["decision.replayKept reason=notApplied"])
            XCTAssertEqual(
                try world.queue.entry(for: first, revision: world.revisions[0])?.state, .failedPermanent)
            XCTAssertNotNil(world.journal.entry(for: first).deletionDecision)
            XCTAssertEqual(
                try world.queue.entry(for: second, revision: world.revisions[0])?.state, .skippedRemoteDeletion)
            XCTAssertNil(world.journal.entry(for: second).deletionDecision)
            XCTAssertEqual(try world.rows().map(\.state), [.skippedRemoteDeletion, .skippedRemoteDeletion])
        }
    }

    @MainActor
    func testAnUnknownReadKeepsEveryRowAndTheIntentForTheNextStart() async throws {
        try await withWorld { world in
            try world.journal.recordDeletionDecision(.keptDeleted, revisions: world.revisions, for: world.source)
            let rows = try world.rows()
            let intent = world.journal.entry(for: world.source).deletionDecision
            let fault = try SQLiteReadInterrupt(
                in: world.queue,
                matching: "SELECT original_filename, byte_count, state", occurrence: 2)
            XCTAssertThrowsError(
                try DeletionDecisionReplay.apply(
                    world.journal.pendingDeletionDecision(for: world.source), queue: world.queue,
                    journal: world.journal, at: world.date))
            XCTAssertTrue(fault.fired)
            fault.stop()
            XCTAssertEqual(try world.rows(), rows)
            XCTAssertEqual(world.journal.entry(for: world.source).deletionDecision, intent)
            let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: world.directory))
            let done = await DeletionDecisionReplay.run(queue: world.queue, journal: reopened, at: world.date)
            XCTAssertTrue(done)
            XCTAssertEqual(try world.rows().map(\.state), [.skippedRemoteDeletion, .skippedRemoteDeletion])
        }
    }

    @MainActor
    func testAFailedReplayWriteKeepsTheIntentAndRetriesAtomically() async throws {
        try await withWorld { world in
            try world.journal.recordDeletionDecision(.keptDeleted, revisions: world.revisions, for: world.source)
            let before = try world.rows()
            let fault = try SQLiteReadInterrupt(
                in: world.queue, matching: "attempts=COALESCE(?, attempts)", occurrence: 2)
            XCTAssertThrowsError(
                try DeletionDecisionReplay.apply(
                    world.journal.pendingDeletionDecision(for: world.source), queue: world.queue,
                    journal: world.journal, at: world.date))
            XCTAssertTrue(fault.fired)
            fault.stop()
            XCTAssertEqual(try world.rows(), before)
            XCTAssertEqual(try world.journal.pendingDeletionDecisions().count, 2)
            try DeletionDecisionReplay.apply(
                try world.journal.pendingDeletionDecision(for: world.source),
                queue: world.queue, journal: world.journal, at: world.date)
            XCTAssertTrue(try world.journal.pendingDeletionDecisions().isEmpty)
        }
    }

    @MainActor
    func testAFailedSettleKeepsTheCommittedChoiceAndOnlySettlesOnReplay() async throws {
        try await withWorld { world in
            world.files.watch(failing: [2])
            try DeletionDecisionReplay.record(
                .keptDeleted, revisions: world.revisions, for: world.source,
                queue: world.queue, journal: world.journal, at: world.date)
            let committed = try world.rows()
            XCTAssertEqual(committed.map(\.state), [.skippedRemoteDeletion, .skippedRemoteDeletion])
            XCTAssertEqual(try world.journal.pendingDeletionDecisions().count, 2)
            world.files.stopWatching()
            let readOnly = try SQLiteReadInterrupt(in: world.queue, matching: "attempts=COALESCE(?, attempts)")
            try DeletionDecisionReplay.apply(
                try world.journal.pendingDeletionDecision(for: world.source),
                queue: world.queue, journal: world.journal, at: world.date.addingTimeInterval(100))
            XCTAssertFalse(readOnly.fired, "rows at their target need no second queue write")
            readOnly.stop()
            XCTAssertEqual(try world.rows(), committed)
            XCTAssertTrue(try world.journal.pendingDeletionDecisions().isEmpty)
        }
    }

    @MainActor
    func testAnOlderSettleCannotEraseANewerIntent() async throws {
        try await withWorld { world in
            let older = try world.journal.recordDeletionDecision(
                .keptDeleted, revisions: world.revisions, for: world.source)
            let newer = try world.journal.recordDeletionDecision(
                .backUpAgain(world.revisions[1]),
                revisions: world.revisions, for: world.source)
            let before = try Data(contentsOf: world.logURL)
            try world.journal.settleDeletionDecision(id: older.id, for: world.source)
            XCTAssertEqual(world.journal.entry(for: world.source).deletionDecision, newer)
            XCTAssertEqual(try Data(contentsOf: world.logURL), before)
        }
    }

    @MainActor
    func testClearAndCompensationMoveTheIntentWithTheChoice() async throws {
        try await withWorld { world in
            let previous = world.journal.entry(for: world.source).deletionChoice
            try world.journal.recordDeletionDecision(.keptDeleted, revisions: world.revisions, for: world.source)
            let written = world.journal.entry(for: world.source).deletionChoice
            try world.journal.restoreDeletionChoice(previous, ifStill: written, for: world.source)
            XCTAssertEqual(world.journal.entry(for: world.source).deletionChoice, previous)
            XCTAssertTrue(try world.journal.pendingDeletionDecisions().isEmpty)
            try world.journal.recordDeletionDecision(.keptDeleted, revisions: world.revisions, for: world.source)
            try world.journal.clearDeletionChoice(for: world.source)
            XCTAssertNil(world.journal.entry(for: world.source).deletionDecision)
            let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: world.directory))
            XCTAssertTrue(try reopened.pendingDeletionDecisions().isEmpty)
        }
    }

    #if DEBUG
        /// The person's latest choice wins. A tap in the start window, before the launch replay ran, records and
        /// applies the new choice. The recorded earlier choice is never applied, and the replay after it writes
        /// nothing.
        @MainActor
        func testANewChoiceInTheStartWindowReplacesTheRecordedChoice() async throws {
            try await withWorld { world in
                try world.journal.recordDeletionDecision(
                    .backUpAgain(world.revisions[1]),
                    revisions: world.revisions, for: world.source)
                let suite = UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let lines = RecordedLogLines()
                var configuration = PhotoLibraryBackupController.Configuration(
                    accountDataDirectory: world.directory, databasePolicy: .conservative, defaults: defaults)
                configuration.backgroundLog = BackgroundWorkLog { lines.append($1) }
                let controller = PhotoLibraryBackupController(
                    configuration: configuration, identityResolver: nil, uploader: MockUploader(),
                    replacementJournal: world.journal)
                // No await lets the launch task run before this call: the earlier choice is recorded and unapplied.
                XCTAssertTrue(controller.keepDeleted(BackupFailedItem(entry: world.entry(world.revisions[1]))))
                XCTAssertEqual(try world.rows().map(\.state), [.skippedRemoteDeletion, .skippedRemoteDeletion])
                XCTAssertNil(world.journal.entry(for: world.source).backUpAgainRevision)
                XCTAssertEqual(world.journal.entry(for: world.source).keptDeleted, true)
                await controller.waitForLaunchDeletionReplayForTesting()
                XCTAssertEqual(try world.rows().map(\.state), [.skippedRemoteDeletion, .skippedRemoteDeletion])
                XCTAssertTrue(try world.journal.pendingDeletionDecisions().isEmpty)
                XCTAssertEqual(
                    lines.values.filter { $0.hasPrefix("decision.") }, ["decision.replaced reason=notApplied"])
                await controller.shutdown()
            }
        }

        /// A choice whose queue write and take-back both failed stays recorded. The person's next choice for the photo
        /// is the one that is recorded and applied; the stuck choice is never applied, also not by a later replay.
        @MainActor
        func testANewChoiceAfterAStuckChoiceAppliesOnlyTheNewChoice() async throws {
            try await withWorld { world in
                let journal = RefusingJournal(inner: world.journal, refusesRestore: true)
                try await withController(world, journal: journal) { controller, lines in
                    await controller.waitForLaunchDeletionReplayForTesting()
                    let item = BackupFailedItem(entry: world.entry(world.revisions[1]))
                    let fault = try SQLiteReadInterrupt(
                        in: try XCTUnwrap(controller.queueStoreForTesting), matching: "attempts=COALESCE(?, attempts)",
                        occurrence: 1)
                    XCTAssertFalse(controller.backUpAgain(item))
                    XCTAssertTrue(fault.fired)
                    fault.stop()
                    XCTAssertEqual(try world.rows().map(\.state), [.failedPermanent, .failedPermanent])
                    XCTAssertNotNil(world.journal.entry(for: world.source).deletionDecision, "the stuck choice stays")

                    XCTAssertTrue(controller.keepDeleted(item))

                    XCTAssertEqual(try world.rows().map(\.state), [.skippedRemoteDeletion, .skippedRemoteDeletion])
                    let entry = world.journal.entry(for: world.source)
                    XCTAssertEqual(entry.keptDeleted, true)
                    XCTAssertNil(entry.backUpAgainRevision)
                    XCTAssertNil(entry.deletionDecision)
                    XCTAssertEqual(
                        lines.values.filter { $0.hasPrefix("decision.") },
                        [
                            "decision.choiceNotRestored choice=backUpAgain", "decision.notSaved choice=backUpAgain",
                            "decision.replaced reason=notApplied",
                        ])
                    let rows = try world.rows()
                    let done = await DeletionDecisionReplay.run(
                        queue: world.queue, journal: world.journal, at: world.date)
                    XCTAssertTrue(done)
                    XCTAssertEqual(try world.rows(), rows)
                }
            }
        }

        /// The earlier choice committed its queue write, but its clear failed. A new choice for a later parked revision
        /// settles the earlier intent first and then applies to the rows as they are now: the moved revision stays.
        @MainActor
        func testAnAppliedEarlierChoiceIsSettledAndTheNewChoiceApplies() async throws {
            try await withWorld { world in
                try await withController(world) { controller, lines in
                    await controller.waitForLaunchDeletionReplayForTesting()
                    try world.recordAppliedChoice(.keptDeleted, revisions: [world.revisions[0]])
                    let moved = try world.rows()[0]
                    XCTAssertEqual(moved.state, .skippedRemoteDeletion)

                    XCTAssertTrue(controller.backUpAgain(BackupFailedItem(entry: world.entry(world.revisions[1]))))

                    XCTAssertEqual(try world.rows()[0], moved)
                    XCTAssertEqual(try world.rows()[1].state, .discovered)
                    let entry = world.journal.entry(for: world.source)
                    XCTAssertEqual(entry.backUpAgainRevision, world.revisions[1])
                    XCTAssertNil(entry.keptDeleted)
                    XCTAssertNil(entry.deletionDecision)
                    XCTAssertTrue(lines.values.filter { $0.hasPrefix("decision.") }.isEmpty, "nothing was replaced")
                }
            }
        }

        /// A tap on a row that an applied earlier choice already moved changes no row and shows no error. It settles
        /// the earlier intent, so no later replay holds it.
        @MainActor
        func testATapOnAMovedRowSettlesTheAppliedEarlierChoice() async throws {
            try await withWorld { world in
                try await withController(world) { controller, lines in
                    await controller.waitForLaunchDeletionReplayForTesting()
                    try world.recordAppliedChoice(.keptDeleted, revisions: world.revisions)
                    let rows = try world.rows()

                    XCTAssertFalse(controller.keepDeleted(BackupFailedItem(entry: world.entry(world.revisions[1]))))

                    XCTAssertEqual(try world.rows(), rows)
                    XCTAssertNil(world.journal.entry(for: world.source).deletionDecision)
                    XCTAssertEqual(world.journal.entry(for: world.source).keptDeleted, true)
                    XCTAssertNil(controller.lastMessage)
                    XCTAssertTrue(lines.values.filter { $0.hasPrefix("decision.") }.isEmpty)
                }
            }
        }

        /// A malformed intent cannot be read, so the launch replay keeps it. The person's next choice for the photo
        /// replaces it instead of failing on it again; the log names no photo.
        @MainActor
        func testANewChoiceReplacesAMalformedIntent() async throws {
            try await withWorld { world in
                var bytes = try JSONEncoder().encode(
                    RecordedDeletionLine(
                        key: "photoLibraryAsset|replay-photo|primary",
                        entry: .init(deletionDecision: DeletionDecisionIntent(revisions: world.revisions))))
                bytes.append(10)
                try bytes.write(to: world.logURL, options: .atomic)
                let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: world.directory))
                try await withController(world, journal: journal) { controller, lines in
                    await controller.waitForLaunchDeletionReplayForTesting()
                    XCTAssertEqual(
                        lines.values.filter { $0.hasPrefix("decision.") }, ["decision.replayKept reason=unreadable"])

                    XCTAssertTrue(controller.keepDeleted(BackupFailedItem(entry: world.entry(world.revisions[1]))))

                    XCTAssertEqual(try world.rows().map(\.state), [.skippedRemoteDeletion, .skippedRemoteDeletion])
                    XCTAssertEqual(journal.entry(for: world.source).keptDeleted, true)
                    XCTAssertNil(journal.entry(for: world.source).deletionDecision)
                    XCTAssertTrue(try journal.pendingDeletionDecisions().isEmpty)
                    XCTAssertEqual(
                        lines.values.filter { $0.hasPrefix("decision.") },
                        ["decision.replayKept reason=unreadable", "decision.replaced reason=unreadable"])
                    for line in lines.values { XCTAssertFalse(line.contains(world.source.identifier)) }
                    let done = await DeletionDecisionReplay.run(queue: world.queue, journal: journal, at: world.date)
                    XCTAssertTrue(done)
                }
            }
        }

        /// The replay finished one photo and waits before the next. The person answers for the next photo meanwhile:
        /// the answer applies, and the replay then finds nothing left to apply for that photo.
        @MainActor
        func testAChoiceWhileTheReplayWaitsAppliesOnlyThatChoice() async throws {
            try await withWorld { world in
                try await withController(world) { controller, _ in
                    await controller.waitForLaunchDeletionReplayForTesting()
                    let first = try world.parkOtherPhoto("a-first-photo")
                    try world.journal.recordDeletionDecision(
                        .keptDeleted, revisions: [first.revision], for: first.source)
                    try world.journal.recordDeletionDecision(
                        .backUpAgain(world.revisions[1]), revisions: world.revisions, for: world.source)
                    let stop = ReplayInterruption()

                    let done = await DeletionDecisionReplay.run(
                        queue: world.queue, journal: world.journal, at: world.date,
                        shouldStop: {
                            stop.checks += 1
                            if stop.checks == 2 {
                                stop.decided = controller.keepDeleted(
                                    BackupFailedItem(entry: world.entry(world.revisions[1])))
                            }
                            return false
                        })

                    XCTAssertTrue(done)
                    XCTAssertEqual(stop.decided, true)
                    XCTAssertEqual(
                        try world.queue.entry(for: first.source, revision: first.revision)?.state,
                        .skippedRemoteDeletion)
                    XCTAssertEqual(try world.rows().map(\.state), [.skippedRemoteDeletion, .skippedRemoteDeletion])
                    XCTAssertTrue(try world.journal.pendingDeletionDecisions().isEmpty)
                }
            }
        }

        /// A replay that stops after the person answered for one photo, by cancellation or by shutdown, keeps exactly
        /// one intent for each photo: none for the answered photo, the recorded one for the other. The next launch
        /// applies it.
        @MainActor
        func testCancellationAndShutdownAfterANewChoiceKeepExactlyOneIntent() async throws {
            for cancels in [true, false] {
                try await withWorld { world in
                    try await withController(world) { controller, _ in
                        await controller.waitForLaunchDeletionReplayForTesting()
                        let first = try world.parkOtherPhoto("a-first-photo")
                        try world.journal.recordDeletionDecision(
                            .backUpAgain(first.revision), revisions: [first.revision], for: first.source)
                        let other = try world.journal.recordDeletionDecision(
                            .keptDeleted, revisions: world.revisions, for: world.source)
                        let stop = ReplayInterruption()

                        let replay = Task { @MainActor in
                            await DeletionDecisionReplay.run(
                                queue: world.queue, journal: world.journal, at: world.date,
                                shouldStop: {
                                    stop.checks += 1
                                    guard stop.checks == 1 else { return true }
                                    stop.decided = controller.keepDeleted(BackupFailedItem(entry: first))
                                    if cancels { withUnsafeCurrentTask { $0?.cancel() } }
                                    return false
                                })
                        }
                        let done = await replay.value

                        XCTAssertFalse(done, "cancels: \(cancels)")
                        XCTAssertEqual(stop.decided, true)
                        XCTAssertEqual(stop.checks, cancels ? 1 : 2, "cancels: \(cancels)")
                        XCTAssertEqual(
                            try world.queue.entry(for: first.source, revision: first.revision)?.state,
                            .skippedRemoteDeletion, "the earlier Back Up Again of the answered photo never applies")
                        XCTAssertNil(world.journal.entry(for: first.source).deletionDecision)
                        XCTAssertEqual(world.journal.entry(for: world.source).deletionDecision, other)
                        XCTAssertEqual(try world.rows().map(\.state), [.failedPermanent, .failedPermanent])
                        let reopened = try XCTUnwrap(
                            EditReplacementJournalFileStore(accountDataDirectory: world.directory))
                        let resumed = await DeletionDecisionReplay.run(
                            queue: world.queue, journal: reopened, at: world.date)
                        XCTAssertTrue(resumed)
                        XCTAssertEqual(try world.rows().map(\.state), [.skippedRemoteDeletion, .skippedRemoteDeletion])
                        XCTAssertEqual(
                            try world.queue.entry(for: first.source, revision: first.revision)?.state,
                            .skippedRemoteDeletion)
                    }
                }
            }
        }

        /// Each stop of a new choice that replaces a stuck choice leaves exactly one intent, and the next launch
        /// applies exactly that one: the stuck choice when the new line was not written, the new choice from its line
        /// on.
        @MainActor
        func testEveryStopOfANewChoiceKeepsExactlyOneIntent() async throws {
            enum Stop: CaseIterable { case newLine, queueWrite, clear }
            for stop in Stop.allCases {
                try await withWorld { world in
                    try await withController(world) { controller, lines in
                        await controller.waitForLaunchDeletionReplayForTesting()
                        let stuck = try world.journal.recordDeletionDecision(
                            .backUpAgain(world.revisions[1]), revisions: world.revisions, for: world.source)
                        let item = BackupFailedItem(entry: world.entry(world.revisions[1]))
                        var fault: SQLiteReadInterrupt?
                        switch stop {
                        case .newLine: world.files.watch(failing: [1])
                        case .clear: world.files.watch(failing: [2])
                        case .queueWrite:
                            fault = try SQLiteReadInterrupt(
                                in: try XCTUnwrap(controller.queueStoreForTesting),
                                matching: "attempts=COALESCE(?, attempts)", occurrence: 1)
                        }

                        let decided = controller.keepDeleted(item)

                        world.files.stopWatching()
                        fault?.stop()
                        let intent = world.journal.entry(for: world.source).deletionDecision
                        switch stop {
                        case .newLine:
                            XCTAssertFalse(decided)
                            XCTAssertEqual(intent, stuck, "the new line was not written; the stuck choice stays")
                            XCTAssertEqual(try world.rows().map(\.state), [.failedPermanent, .failedPermanent])
                        case .queueWrite:
                            XCTAssertFalse(decided)
                            XCTAssertEqual(fault?.fired, true)
                            XCTAssertNotNil(intent)
                            XCTAssertNotEqual(intent, stuck, "a failed queue write never brings the stuck choice back")
                            XCTAssertEqual(world.journal.entry(for: world.source).keptDeleted, true)
                            XCTAssertEqual(try world.rows().map(\.state), [.failedPermanent, .failedPermanent])
                            // The choice stays recorded although the person saw the error; the log says so.
                            XCTAssertEqual(
                                lines.values.filter { $0.hasPrefix("decision.") },
                                ["decision.choiceKept choice=keepDeleted", "decision.notSaved choice=keepDeleted"])
                        case .clear:
                            XCTAssertTrue(decided)
                            XCTAssertNotNil(intent)
                            XCTAssertNotEqual(intent, stuck)
                            XCTAssertEqual(
                                try world.rows().map(\.state), [.skippedRemoteDeletion, .skippedRemoteDeletion])
                        }
                        let reopened = try XCTUnwrap(
                            EditReplacementJournalFileStore(accountDataDirectory: world.directory))
                        let done = await DeletionDecisionReplay.run(
                            queue: world.queue, journal: reopened, at: world.date)
                        XCTAssertTrue(done, "\(stop)")
                        XCTAssertTrue(try reopened.pendingDeletionDecisions().isEmpty, "\(stop)")
                        XCTAssertEqual(
                            try world.rows().map(\.state),
                            stop == .newLine
                                ? [.dismissedFailure, .discovered] : [.skippedRemoteDeletion, .skippedRemoteDeletion],
                            "\(stop)")
                    }
                }
            }
        }

        /// A queue with a recorded failure may miss a parked row on a read. A new choice then neither settles the stuck
        /// intent nor replaces it: the person sees the local-state error and the stuck intent stays for a later start.
        @MainActor
        func testANewChoiceOnAQueueWithARecordedFailureLeavesTheStuckChoice() async throws {
            try await withWorld { world in
                try await withController(world) { controller, _ in
                    await controller.waitForLaunchDeletionReplayForTesting()
                    let stuck = try world.journal.recordDeletionDecision(
                        .backUpAgain(world.revisions[1]), revisions: world.revisions, for: world.source)
                    let other = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "undecodable-photo")
                    var otherRow = world.entry(world.revisions[0])
                    otherRow.source = other
                    XCTAssertTrue(world.queue.upsert(otherRow))
                    var handle: OpaquePointer?
                    let url = world.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)
                    XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
                    XCTAssertEqual(
                        sqlite3_exec(
                            handle,
                            "UPDATE backup_sync_queue SET remote_commit_reconciliation=X'7B' "
                                + "WHERE source_id='undecodable-photo';", nil, nil, nil),
                        SQLITE_OK)
                    sqlite3_close(handle)
                    let store = try XCTUnwrap(controller.queueStoreForTesting)
                    XCTAssertThrowsError(try store.entry(for: other, revision: otherRow.revision))
                    XCTAssertFalse(store.isOperational(), "the undecodable row records a lasting failure")
                    let rows = try world.rows()

                    // Such a queue cannot tell whether the earlier choice was applied, so the preparation throws and
                    // settles nothing; its reads would still find the parked rows here and call the choice unapplied.
                    XCTAssertThrowsError(
                        try DeletionDecisionReplay.prepareLatestChoice(
                            for: world.source, queue: store, journal: world.journal))
                    XCTAssertEqual(world.journal.entry(for: world.source).deletionDecision, stuck)

                    XCTAssertFalse(controller.keepDeleted(BackupFailedItem(entry: world.entry(world.revisions[1]))))

                    XCTAssertEqual(world.journal.entry(for: world.source).deletionDecision, stuck)
                    XCTAssertEqual(try world.rows(), rows, "no revision changes")
                    XCTAssertEqual(controller.lastMessage, L10n.string("backup.error_local_state_unavailable"))
                }
            }
        }

        /// A controller on the world's account with a recording background log. It shuts down after `body`.
        @MainActor
        private func withController(
            _ world: DeletionReplayWorld, journal: (any EditReplacementJournaling)? = nil,
            _ body: (PhotoLibraryBackupController, RecordedLogLines) async throws -> Void
        ) async throws {
            let suite = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let lines = RecordedLogLines()
            var configuration = PhotoLibraryBackupController.Configuration(
                accountDataDirectory: world.directory, databasePolicy: .conservative, defaults: defaults)
            configuration.backgroundLog = BackgroundWorkLog { lines.append($1) }
            let controller = PhotoLibraryBackupController(
                configuration: configuration, identityResolver: nil, uploader: MockUploader(),
                replacementJournal: journal ?? world.journal)
            do {
                try await body(controller, lines)
            } catch {
                await controller.shutdown()
                throw error
            }
            await controller.shutdown()
        }
    #endif

    func testRecordedLinesConvertToEveryDecisionColumn() throws {
        for (line, choice, reopened, id) in [
            (
                Self.keepLine, DeletionDecisionRow.Choice.keepDeleted, nil as Int64?,
                "6B29FC40-CA47-1067-B31D-00DD010662DA"
            ),
            (Self.backUpAgainLine, .backUpAgain, 742_000_061_000_000, "6B29FC40-CA47-1067-B31D-00DD010662DB"),
        ] {
            let decoded = try JSONDecoder().decode(RecordedDeletionLine.self, from: Data(line.utf8))
            let rows = try DeletionDecisionRow.rows(key: decoded.key, entry: decoded.entry)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(
                rows.map(\.decisionID), [try XCTUnwrap(UUID(uuidString: id)), try XCTUnwrap(UUID(uuidString: id))])
            XCTAssertEqual(rows.map(\.sourceKind), [.photoLibraryAsset, .photoLibraryAsset])
            XCTAssertEqual(rows.map(\.sourceID), ["deleted-photo", "deleted-photo"])
            XCTAssertEqual(rows.map(\.resource), ["primary", "primary"])
            XCTAssertEqual(rows.map(\.choice), [choice, choice])
            XCTAssertEqual(rows.map(\.reopenedRevision), [reopened, reopened])
            XCTAssertEqual(rows.map(\.revision), [742_000_001_000_000, 742_000_061_000_000])
        }
        XCTAssertTrue(
            try DeletionDecisionRow.rows(key: "photoLibraryAsset|old|primary", entry: .init(keptDeleted: true)).isEmpty)
    }

    func testMalformedIntentsAreUnknownInsteadOfAbsent() throws {
        let intent = DeletionDecisionIntent(revisions: [.init(rawValue: 1)])
        for entry in [
            EditReplacementJournalEntry(keptDeleted: true, deletionDecision: DeletionDecisionIntent(revisions: [])),
            EditReplacementJournalEntry(deletionDecision: intent),
            .init(keptDeleted: true, backUpAgainRevision: .init(rawValue: 1), deletionDecision: intent),
            .init(backUpAgainRevision: .init(rawValue: 2), deletionDecision: intent),
        ] {
            XCTAssertThrowsError(try DeletionDecisionRow.rows(key: "photoLibraryAsset|photo|primary", entry: entry))
        }
        for key in ["photoLibraryAsset|primary", "futureKind|photo|primary", "photoLibraryAsset|photo|"] {
            XCTAssertThrowsError(
                try DeletionDecisionRow.rows(key: key, entry: .init(keptDeleted: true, deletionDecision: intent)))
        }
    }

    @MainActor
    func testAnUnrelatedWriteKeepsAnUnreadableIntent() async throws {
        try await withWorld { world in
            let intent = DeletionDecisionIntent(revisions: world.revisions)
            var bytes = try JSONEncoder().encode(
                RecordedDeletionLine(
                    key: "photoLibraryAsset|replay-photo|primary", entry: .init(deletionDecision: intent)))
            bytes.append(10)
            try bytes.write(to: world.logURL, options: .atomic)
            let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: world.directory))
            XCTAssertThrowsError(try journal.pendingDeletionDecisions())
            try journal.recordUpload(edited: false, for: world.source)
            XCTAssertEqual(journal.entry(for: world.source).deletionDecision, intent)
            XCTAssertEqual(try Data(contentsOf: world.logURL), bytes)
            XCTAssertThrowsError(try journal.pendingDeletionDecisions())
        }
    }

    @MainActor
    func testAnUnreadableIntentDoesNotStopOtherPhotosFromReplaying() async throws {
        try await withWorld { world in
            let unreadable = DeletionDecisionIntent(revisions: world.revisions)
            var bytes = try JSONEncoder().encode(
                RecordedDeletionLine(
                    key: "photoLibraryAsset|replay-photo|primary", entry: .init(deletionDecision: unreadable)))
            bytes.append(10)
            try bytes.write(to: world.logURL, options: .atomic)
            let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: world.directory))
            let other = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "z-healthy-photo")
            var row = world.entry(world.revisions[0])
            row.source = other
            XCTAssertTrue(world.queue.upsert(row))
            try journal.recordDeletionDecision(.keptDeleted, revisions: [row.revision], for: other)

            let lines = RecordedLogLines()
            let done = await DeletionDecisionReplay.run(
                queue: world.queue, journal: journal, at: world.date, log: BackgroundWorkLog { lines.append($1) })

            XCTAssertFalse(done)
            XCTAssertEqual(lines.values, ["decision.replayKept reason=unreadable"])
            XCTAssertEqual(try world.queue.entry(for: other, revision: row.revision)?.state, .skippedRemoteDeletion)
            XCTAssertNil(journal.entry(for: other).deletionDecision)
            XCTAssertEqual(journal.entry(for: world.source).deletionDecision, unreadable)
            XCTAssertEqual(try world.rows().map(\.state), [.failedPermanent, .failedPermanent])
        }
    }

    @MainActor
    func testCancellationStopsBetweenSourcesAndRetainsTheRemainingIntent() async throws {
        try await withWorld { world in
            let other = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "other-photo")
            var otherRow = world.entry(world.revisions[0])
            otherRow.source = other
            XCTAssertTrue(world.queue.upsert(otherRow))
            try world.journal.recordDeletionDecision(.keptDeleted, revisions: world.revisions, for: world.source)
            try world.journal.recordDeletionDecision(.keptDeleted, revisions: [otherRow.revision], for: other)
            var writes = 0
            world.files.watch(
                failing: [],
                onStart: { _ in
                    writes += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                })
            let replay = Task { @MainActor in
                await DeletionDecisionReplay.run(queue: world.queue, journal: world.journal, at: world.date)
            }
            let done = await replay.value
            world.files.stopWatching()

            XCTAssertFalse(done)
            XCTAssertEqual(writes, 1, "finish the current source, then stop before another source")
            let pending = try world.journal.pendingDeletionDecisions()
            XCTAssertFalse(pending.isEmpty)
            XCTAssertEqual(Set(pending.map(\.source)).count, 1)
            let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: world.directory))
            let resumed = await DeletionDecisionReplay.run(queue: world.queue, journal: reopened, at: world.date)
            XCTAssertTrue(resumed)
            XCTAssertTrue(try reopened.pendingDeletionDecisions().isEmpty)
        }
    }

    @MainActor
    func testShutdownStopsReplayAndKeepsPendingChoicesForTheNextLaunch() async throws {
        try await withWorld { world in
            try world.journal.recordDeletionDecision(.keptDeleted, revisions: world.revisions, for: world.source)
            let suite = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: world.directory, databasePolicy: .conservative, defaults: defaults),
                identityResolver: nil, uploader: MockUploader(), replacementJournal: world.journal)
            await controller.shutdown()
            XCTAssertEqual(try world.rows().map(\.state), [.failedPermanent, .failedPermanent])
            XCTAssertEqual(try world.journal.pendingDeletionDecisions().count, 2)
            let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: world.directory))
            let resumed = await DeletionDecisionReplay.run(queue: world.queue, journal: reopened, at: world.date)
            XCTAssertTrue(resumed)
            XCTAssertEqual(try world.rows().map(\.state), [.skippedRemoteDeletion, .skippedRemoteDeletion])
        }
    }

    @MainActor
    func testAFailedReadAfterTheAppendRestoresThePreviousChoice() async throws {
        try await withWorld { world in
            let journal = RefusingJournal(inner: world.journal, refusesReadAfterRecord: true)
            let previous = world.journal.entry(for: world.source)
            let rows = try world.rows()
            XCTAssertThrowsError(
                try DeletionDecisionReplay.record(
                    .keptDeleted, revisions: world.revisions, for: world.source,
                    queue: world.queue, journal: journal, at: world.date)
            ) { error in
                XCTAssertEqual(
                    error as? UploadError, .backend(L10n.string("backup.error_local_state_unavailable")),
                    "the caller gets the local-state error, not the error of the failed read")
            }
            XCTAssertEqual(try world.rows(), rows)
            XCTAssertEqual(world.journal.entry(for: world.source), previous)
            XCTAssertEqual(journal.restoreAttempts, 1)
            XCTAssertTrue(try world.journal.pendingDeletionDecisions().isEmpty)
        }
    }

    @MainActor
    func testReplayBudgetWithFiftyThousandHistoricalAndPendingEntries() async throws {
        try await withWorld { world in
            let encoder = JSONEncoder()
            var bytes = Data()
            var parked: [UploadBackupSyncQueueEntry] = []
            for i in 0..<50_000 {
                var row = world.entry(.init(rawValue: 1))
                row.source = .init(kind: .photoLibraryAsset, identifier: "budget-\(i)")
                parked.append(row)
                bytes.append(
                    try encoder.encode(
                        RecordedDeletionLine(
                            key: "photoLibraryAsset|budget-\(i)|primary",
                            entry: .init(keptDeleted: true))))
                bytes.append(10)
            }
            XCTAssertTrue(world.queue.upsertBatch(parked))
            try bytes.write(to: world.logURL, options: .atomic)
            let historical = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: world.directory))
            let emptyStart = ContinuousClock.now
            let emptyDone = await DeletionDecisionReplay.run(queue: world.queue, journal: historical, at: world.date)
            let emptyElapsed = emptyStart.duration(to: .now)
            XCTAssertTrue(emptyDone)
            XCTAssertEqual(try Data(contentsOf: world.logURL), bytes)
            bytes.removeAll(keepingCapacity: true)
            let intent = DeletionDecisionIntent(revisions: [.init(rawValue: 1)])
            for i in 0..<50_000 {
                bytes.append(
                    try encoder.encode(
                        RecordedDeletionLine(
                            key: "photoLibraryAsset|budget-\(i)|primary",
                            entry: .init(keptDeleted: true, deletionDecision: intent))))
                bytes.append(10)
            }
            try bytes.write(to: world.logURL, options: .atomic)
            let pending = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: world.directory))
            XCTAssertEqual(try pending.pendingDeletionDecisions().count, 50_000)
            let start = ContinuousClock.now
            let done = await DeletionDecisionReplay.run(queue: world.queue, journal: pending, at: world.date)
            print(
                "deletion replay budget: historical=50000 pending=0 \(emptyElapsed); pending=50000 parked=50000 \(start.duration(to: .now))"
            )
            XCTAssertTrue(done)
            XCTAssertTrue(try pending.pendingDeletionDecisions().isEmpty)
            for row in [parked[0], parked[49_999]] {
                XCTAssertEqual(
                    try world.queue.entry(for: row.source, revision: row.revision)?.state, .skippedRemoteDeletion)
            }
        }
    }

    // MARK: Earlier builds

    private static let keepLine =
        #"{"key":"photoLibraryAsset|deleted-photo|primary","entry":{"superseded":[{"volumeID":"vol","#
        + #""nodeID":"gone"}],"retired":[],"keptDeleted":true,"#
        + #""deletionDecision":{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","#
        + #""revisions":[{"rawValue":742000001000000},{"rawValue":742000061000000}]}}}"#

    private static let backUpAgainLine =
        #"{"key":"photoLibraryAsset|deleted-photo|primary","entry":{"superseded":[{"volumeID":"vol","#
        + #""nodeID":"gone"}],"retired":[],"backUpAgainRevision":{"rawValue":742000061000000},"#
        + #""deletionDecision":{"id":"6B29FC40-CA47-1067-B31D-00DD010662DB","#
        + #""revisions":[{"rawValue":742000001000000},{"rawValue":742000061000000}]}}}"#

    func testAnEarlierBuildReadsALineWithADeletionDecisionAndKeepsTheChoice() throws {
        let decoder = JSONDecoder()
        let keep = try decoder.decode(EarlierBuildLine.self, from: Data(Self.keepLine.utf8))
        XCTAssertEqual(keep.key, "photoLibraryAsset|deleted-photo|primary")
        XCTAssertEqual(
            keep.entry,
            EarlierBuildEntry(
                superseded: [PhotoUID(volumeID: "vol", nodeID: "gone")], retired: [], keptDeleted: true))

        let again = try decoder.decode(EarlierBuildLine.self, from: Data(Self.backUpAgainLine.utf8))
        XCTAssertEqual(
            again.entry,
            EarlierBuildEntry(
                superseded: [PhotoUID(volumeID: "vol", nodeID: "gone")], retired: [],
                backUpAgainRevision: UploadBackupRevision(rawValue: 742_000_061_000_000)))
    }
}

private struct RecordedDeletionLine: Codable {
    let key: String
    let entry: EditReplacementJournalEntry
}

private struct DeletionReplayWorld {
    let directory: URL
    let queue: UploadBackupSyncQueueManifestStore
    let journal: EditReplacementJournalFileStore
    let files: StorageFaultFiles
    let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "replay-photo")
    let revisions = [UploadBackupRevision(rawValue: 1), UploadBackupRevision(rawValue: 2)]
    let date = Date(timeIntervalSince1970: 1_720_000_001)
    var logURL: URL { directory.appendingPathComponent(EditReplacementJournalFileStore.logFileName) }

    func entry(
        _ revision: UploadBackupRevision, state: UploadBackupSyncQueueState = .failedPermanent
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: source, revision: revision, originalFilename: "photo.heic", state: state,
            lastError: state == .failedPermanent
                ? BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue : nil,
            updatedAt: date)
    }

    func rows() throws -> [UploadBackupSyncQueueEntry] {
        try revisions.map { try XCTUnwrap(queue.entry(for: source, revision: $0)) }
    }

    /// The state that a choice leaves when its queue write committed and its clear failed.
    @MainActor
    func recordAppliedChoice(_ choice: EditReplacementDeletionChoice, revisions: [UploadBackupRevision]) throws {
        try journal.recordDeletionDecision(choice, revisions: revisions, for: source)
        let updates = try journal.pendingDeletionDecision(for: source).map(\.update)
        XCTAssertTrue(queue.updateStates(of: source, updates, updatedAt: date))
    }

    /// One parked revision of another photo.
    func parkOtherPhoto(_ identifier: String) throws -> UploadBackupSyncQueueEntry {
        var row = entry(revisions[0])
        row.source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier)
        XCTAssertTrue(queue.upsert(row))
        return row
    }
}

/// What a replay's stop check saw, and the person's answer given during it.
@MainActor
private final class ReplayInterruption {
    var checks = 0
    var decided: Bool?
}

extension EarlierBuildEntry {
    init(
        superseded: [PhotoUID], retired: [String], keptDeleted: Bool? = nil,
        backUpAgainRevision: UploadBackupRevision? = nil
    ) {
        self.init(
            superseded: superseded, remoteSuperseded: nil, retired: retired, uploadedEdit: nil, retireIntent: nil,
            proven: nil, inherited: nil, gone: nil, keptDeleted: keptDeleted, backUpAgainRevision: backUpAgainRevision,
            deletionCheckStartedAt: nil)
    }
}
