import AlbumSyncCore
import Foundation
import PhotosCore
import SQLite3
import SQLiteTestSupport
import UploadCore
import XCTest

@testable import PhotoLibraryBackupAdapter

/// Album Sync resets its queue before each run, and each run holds only one album's photos. Proton's refusal rounds of
/// a photo live in a file next to the queue, so a photo that Proton refused until the backup stopped is not uploaded
/// again on every album run, also when other albums sync in between (#884).
///
/// The real album executor, runner, dedupe pipeline and identity manifest run. Only the PhotoKit scan and the
/// uploader are replaced.
final class AlbumSyncRefusalCarryTests: XCTestCase {
    private var tempDir: URL!
    private var accountDir: URL!
    private var clock: BackupTestClock!
    private var manifest: UploadIdentityManifestStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var resolver: ScriptedBackupResolver!
    private var uploader: MockUploader!

    private let source = photoLibrarySource("photo")
    private var revision: UploadBackupRevision { UploadBackupRevision(date: resolver.defaultModified) }
    private var queueURL: URL { accountDir.appendingPathComponent(PhotoAlbumBackupExecutor.queueDatabaseFileName) }
    private var refusalStore: AlbumSyncRefusalStore { AlbumSyncRefusalStore(accountDataDirectory: accountDir) }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-sync-refusal-carry-\(UUID().uuidString)", isDirectory: true)
        accountDir = tempDir.appendingPathComponent("account", isDirectory: true)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        // The scan dates its rows with the wall clock, so the runner's clock starts there to find them due.
        clock = BackupTestClock(start: Date())
        manifest = try XCTUnwrap(UploadIdentityManifestStore(url: tempDir.appendingPathComponent("manifest.sqlite")))
        hasher = FakeHasher()
        checker = FakeChecker()
        resolver = ScriptedBackupResolver(defaultModified: clock.now.addingTimeInterval(-3600))
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
    }

    override func tearDownWithError() throws {
        manifest.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Streams fixed candidates instead of scanning PhotoKit, and runs `onScan` once the scan reads them.
    private struct ScanCandidates: UploadBackupAssetCatalog {
        let items: [UploadBackupAssetCandidate]
        var onScan: (@Sendable () throws -> Void)?
        func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
            AsyncThrowingStream { continuation in
                do {
                    try onScan?()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                for item in items { continuation.yield(item) }
                continuation.finish()
            }
        }
    }

    private var externalIdentity: UploadBackupExternalIdentity? = nil

    private func candidate(_ identifier: String, revision: UploadBackupRevision) -> UploadBackupAssetCandidate {
        UploadBackupAssetCandidate(
            snapshot: UploadBackupAssetSnapshot(
                source: photoLibrarySource(identifier), revision: revision,
                resourceCount: 1, externalIdentity: identifier == "photo" ? externalIdentity : nil),
            originalFilename: "\(identifier).heic", byteCount: 4)
    }

    private let logLines = RecordedLogLines()

    private func makeExecutor(
        appBuild: String? = nil, photos: [String] = ["photo"], accountDirectory: URL? = nil,
        refusalFileSystem: any DurableFileSystem = LocalDurableFileSystem(),
        onScan: (@Sendable () throws -> Void)? = nil
    ) -> PhotoAlbumBackupExecutor {
        PhotoAlbumBackupExecutor(
            accountDataDirectory: accountDirectory ?? accountDir,
            databasePolicy: .conservative,
            identityResolver: UploadDedupePipeline(
                store: manifest, hasher: hasher, checker: checker, now: { [clock] in clock!.now }),
            uploader: uploader,
            resourceResolver: resolver,
            proofCatalog: ScanCandidates(items: photos.map { candidate($0, revision: revision) }, onScan: onScan),
            runtimeSignals: .wiFiWithMobileDataOff,
            clock: clock,
            now: { [clock] in clock!.now },
            appBuild: appBuild,
            refusalFileSystem: refusalFileSystem,
            log: BackgroundWorkLog { [logLines] _, line in logLines.append(line) })
    }

    /// One album run with `photos`.
    private func sync(appBuild: String? = nil, photos: [String] = ["photo"]) async throws -> AlbumSyncBackupReport {
        try await makeExecutor(appBuild: appBuild, photos: photos).ensureBackedUp(localIdentifiers: photos) { _ in }
    }

    /// The row that the last album run left in the scratch queue.
    private func scratchRow(revision: UploadBackupRevision? = nil) throws -> UploadBackupSyncQueueEntry? {
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        defer { queue.close() }
        return try queue.entry(for: source, revision: revision ?? self.revision)
    }

    private func refusal(of row: UploadBackupSyncQueueEntry?) -> BackupServiceRejection? {
        BackupIssueRecord.decode(row?.lastError)?.serviceRejection
    }

    /// The stored entry of `identifier`, read through the store's own typed read.
    private func storedEntry(_ identifier: String = "photo") throws -> AlbumSyncRefusalStore.Entry? {
        guard case .found(let entries) = refusalStore.read() else {
            XCTFail("the refusal file is not readable: \(refusalStore.read())")
            return nil
        }
        return entries.first { $0.source.identifier == identifier }
    }

    private func storedRounds(_ identifier: String = "photo") throws -> Int? {
        try storedEntry(identifier).flatMap { BackupIssueRecord.decode($0.lastError)?.serviceRejection?.rounds }
    }

    /// An entry that an earlier album run stored after Proton refused the photo until the backup stopped.
    private func seedStoppedRefusal(
        identifier: String = "photo", revision: UploadBackupRevision? = nil, roundBuild: String?
    ) throws {
        let record = serviceRefusalRecord(
            rounds: 3, firstRoundAt: clock.now.addingTimeInterval(-80 * 3600),
            lastRoundAt: clock.now.addingTimeInterval(-3600))
        var entries: [AlbumSyncRefusalStore.Entry] = []
        if case .found(let earlier) = refusalStore.read() { entries = earlier }
        entries.append(
            .init(
                source: photoLibrarySource(identifier), revision: revision ?? self.revision,
                lastError: record, roundBuild: roundBuild))
        try refusalStore.replace(with: entries)
    }

    // MARK: - Refusal rounds survive the queue reset

    func testRefusalRoundsGrowAcrossAlbumRunsUntilTheBackupStopsAndThePhotoIsNotUploadedAgain() async throws {
        uploader.rejectedNames = ["photo.heic"]

        _ = try await sync()
        XCTAssertEqual(uploader.requests.count, 8, "the first run uses the attempt budget once")
        XCTAssertEqual(try scratchRow()?.state, .failed)
        XCTAssertEqual(try storedRounds(), 1)

        clock.advance(by: 36 * 3600)
        _ = try await sync()
        XCTAssertEqual(uploader.requests.count, 16)
        XCTAssertEqual(refusal(of: try scratchRow())?.rounds, 2, "the second run continues the rounds")
        XCTAssertEqual(try storedRounds(), 2)

        clock.advance(by: 40 * 3600)
        _ = try await sync()
        XCTAssertEqual(uploader.requests.count, 24)
        XCTAssertEqual(try scratchRow()?.state, .failedPermanent, "three rounds over three days stop the photo")
        XCTAssertEqual(try storedRounds(), 3)

        clock.advance(by: 3600)
        let report = try await sync()
        XCTAssertEqual(uploader.requests.count, 24, "a stopped photo is not uploaded again")
        XCTAssertEqual(try scratchRow()?.state, .failedPermanent)
        XCTAssertEqual(report.backedUp, 0, "a refused photo never counts as backed up")
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.problems["photo"]?.reason, L10n.string("backup.issue_service_rejected"))
    }

    func testRoundsSurviveTheRunsOfOtherAlbumsAndOfAnEmptyAlbum() async throws {
        uploader.rejectedNames = ["photo.heic"]

        _ = try await sync()
        XCTAssertEqual(try storedRounds(), 1)

        _ = try await sync(photos: ["other"])
        XCTAssertEqual(uploader.requests.filter { $0.name == "other.heic" }.count, 1, "the other album backs up")
        _ = try await sync(photos: [])
        XCTAssertEqual(try storedRounds(), 1, "another album and an empty album keep the photo's rounds")

        clock.advance(by: 36 * 3600)
        _ = try await sync()
        XCTAssertEqual(refusal(of: try scratchRow())?.rounds, 2, "the next run of the album continues the rounds")

        _ = try await sync(photos: ["other"])
        clock.advance(by: 40 * 3600)
        _ = try await sync()
        XCTAssertEqual(try scratchRow()?.state, .failedPermanent, "three rounds over three days stop the photo")

        _ = try await sync(photos: ["other"])
        _ = try await sync(photos: [])
        let before = uploader.requests.filter { $0.name == "photo.heic" }.count
        _ = try await sync()
        XCTAssertEqual(uploader.requests.filter { $0.name == "photo.heic" }.count, before, "it stays stopped")
        XCTAssertEqual(try scratchRow()?.state, .failedPermanent)
    }

    func testAStoppedRefusalStaysStoppedInTheNextAlbumRunOfTheSameBuild() async throws {
        try seedStoppedRefusal(roundBuild: "7")
        uploader.rejectedNames = ["photo.heic"]

        let report = try await sync(appBuild: "7")

        XCTAssertTrue(uploader.requests.isEmpty, "the stopped photo is not uploaded: \(uploader.requests.map(\.name))")
        XCTAssertEqual(try scratchRow()?.state, .failedPermanent)
        XCTAssertEqual(refusal(of: try scratchRow())?.rounds, 3)
        XCTAssertEqual(report.backedUp, 0)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.problems["photo"]?.reason, L10n.string("backup.issue_service_rejected"))
        XCTAssertEqual(try storedEntry()?.roundBuild, "7")
    }

    func testWithoutABuildNumberAStoppedPhotoStaysStoppedAndKeepsItsBuild() async throws {
        try seedStoppedRefusal(roundBuild: "7")
        uploader.rejectedNames = ["photo.heic"]

        _ = try await sync(appBuild: nil)

        XCTAssertTrue(uploader.requests.isEmpty, "a run without a build number reopens nothing")
        XCTAssertEqual(try scratchRow()?.state, .failedPermanent)
        XCTAssertEqual(try storedEntry()?.roundBuild, "7")
    }

    func testAnEntryOfAnotherAlbumBeforeThisPhotoDoesNotEndTheCarry() async throws {
        try seedStoppedRefusal(identifier: "another-album", roundBuild: "7")
        try seedStoppedRefusal(roundBuild: "7")
        uploader.rejectedNames = ["photo.heic"]

        _ = try await sync(appBuild: "7")

        XCTAssertTrue(uploader.requests.isEmpty, "the photo after another album's entry is still carried")
        XCTAssertEqual(try scratchRow()?.state, .failedPermanent)
        XCTAssertNotNil(try storedEntry("another-album"), "another album's entry stays")
    }

    func testAPhotoInTwoAlbumsKeepsOneEntryAcrossBoth() async throws {
        uploader.rejectedNames = ["photo.heic"]

        _ = try await sync(photos: ["photo"])
        clock.advance(by: 36 * 3600)
        _ = try await sync(photos: ["photo", "other"])
        XCTAssertEqual(try storedRounds(), 2, "the second album continues the rounds of the first")
        clock.advance(by: 40 * 3600)
        _ = try await sync(photos: ["photo"])
        XCTAssertEqual(try scratchRow()?.state, .failedPermanent)

        let before = uploader.requests.filter { $0.name == "photo.heic" }.count
        _ = try await sync(photos: ["photo", "other"])
        let after = uploader.requests.filter { $0.name == "photo.heic" }.count
        XCTAssertEqual(after, before, "both albums keep it stopped")
        guard case .found(let entries) = refusalStore.read() else { return XCTFail("the file is readable") }
        XCTAssertEqual(entries.filter { $0.source.identifier == "photo" }.count, 1, "one entry for the photo")
    }

    func testAPhotoThatParksForAnotherCauseStartsItsRoundsAgain() async throws {
        uploader.rejectedNames = ["photo.heic"]
        _ = try await sync()
        XCTAssertEqual(try storedRounds(), 1)

        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false, failNames: ["photo.heic"])
        clock.advance(by: 36 * 3600)
        _ = try await sync()

        XCTAssertEqual(try scratchRow()?.state, .failed)
        XCTAssertNil(refusal(of: try scratchRow()), "another failure ends the refusal rounds")
        XCTAssertNil(try storedEntry(), "the stored rounds go too, as in the main photo backup")
    }

    func testOnlyTheSameRevisionTakesTheRoundsOfThisRun() async throws {
        let earlier = UploadBackupRevision(date: resolver.defaultModified.addingTimeInterval(-86_400))
        try seedStoppedRefusal(revision: earlier, roundBuild: "7")
        uploader.rejectedNames = ["photo.heic"]

        _ = try await sync(appBuild: "7")

        guard case .found(let entries) = refusalStore.read() else { return XCTFail("the file is readable") }
        XCTAssertEqual(entries.map(\.revision), [revision], "only the scanned revision keeps rounds")
        XCTAssertEqual(try storedRounds(), 1, "the new revision starts with its own first round")
    }

    // MARK: - A new build gives a stopped photo one more round

    func testANewBuildGivesAStoppedPhotoOneMoreRoundAndKeepsItsRounds() async throws {
        try seedStoppedRefusal(roundBuild: "7")
        uploader.rejectedNames = ["photo.heic"]

        _ = try await sync(appBuild: "8")

        XCTAssertEqual(uploader.requests.count, 8, "the new build tries the photo for one more round")
        XCTAssertEqual(try scratchRow()?.state, .failedPermanent, "the kept rounds stop it again after that round")
        XCTAssertEqual(refusal(of: try scratchRow())?.rounds, 3)
        XCTAssertEqual(try storedEntry()?.roundBuild, "8")

        clock.advance(by: 3600)
        _ = try await sync(appBuild: "8")
        XCTAssertEqual(uploader.requests.count, 8, "the same build reopens the photo only once")
        XCTAssertEqual(try scratchRow()?.state, .failedPermanent)
    }

    func testTheNewBuildRoundIsSpentOnlyWhenTheRoundRan() async throws {
        try seedStoppedRefusal(roundBuild: "7")
        let slow = MockUploader(workDuration: .seconds(30), deliverProgress: false)
        slow.rejectedNames = ["photo.heic"]
        uploader = slow
        let executor = makeExecutor(appBuild: "8")
        let run = Task { try await executor.ensureBackedUp(localIdentifiers: ["photo"]) { _ in } }
        for _ in 0..<500 where slow.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(slow.requests.isEmpty, "the reopened round started")
        await executor.stop()
        _ = try? await run.value
        XCTAssertEqual(try storedEntry()?.roundBuild, "7", "a stopped run does not spend the new build's round")

        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
        uploader.rejectedNames = ["photo.heic"]
        let before = uploader.requests.count
        _ = try await sync(appBuild: "8")
        XCTAssertEqual(uploader.requests.count - before, 8, "the next run of the new build gives the round")
        XCTAssertEqual(try storedEntry()?.roundBuild, "8")
    }

    // MARK: - Pruning

    func testANewRevisionOfAStoppedPhotoUploadsNormallyAndDropsTheEarlierEntry() async throws {
        let earlier = UploadBackupRevision(date: resolver.defaultModified.addingTimeInterval(-86_400))
        try seedStoppedRefusal(revision: earlier, roundBuild: "7")

        let report = try await sync(appBuild: "7")

        XCTAssertEqual(uploader.requests.map(\.name), ["photo.heic"], "the changed photo starts fresh")
        XCTAssertEqual(report.backedUp, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertNil(try storedEntry(), "the earlier revision's rounds go")
    }

    func testARevisionThatTheScanProvesBackedUpKeepsItsStateAndDropsItsEntry() async throws {
        try seedStoppedRefusal(roundBuild: "7")
        uploader.rejectedNames = ["photo.heic"]
        let identity = UploadBackupExternalIdentity(identifier: "cloud-photo", revision: revision)
        externalIdentity = identity
        checker.remoteAssetProofs = [
            identity: UploadRemoteAssetIndexRecord(
                externalIdentity: identity, resourceCount: 1, remoteLinkIDs: ["main"], hashKeyEpoch: "epoch-1")
        ]

        let report = try await sync(appBuild: "7")

        XCTAssertTrue(uploader.requests.isEmpty, "the proven photo needs no upload")
        XCTAssertEqual(try scratchRow()?.state, .alreadyBackedUp, "the carry never makes a backed-up photo final")
        XCTAssertNil(refusal(of: try scratchRow()))
        XCTAssertEqual(report.backedUp, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertNil(try storedEntry(), "a backed-up photo needs no rounds")
    }

    func testAPhotoThatTheRunDidNotScanKeepsItsEntry() async throws {
        try seedStoppedRefusal(roundBuild: "7")

        _ = try await makeExecutor(appBuild: "7", photos: []).ensureBackedUp(localIdentifiers: ["photo"]) { _ in }

        XCTAssertEqual(try storedEntry()?.roundBuild, "7", "a photo without a row is not proven backed up")
    }

    // MARK: - A lost carry costs only retries

    func testAFailedCarryWriteMarksNothingDoneAndKeepsTheStoredRounds() async throws {
        try seedStoppedRefusal(roundBuild: "7")
        uploader.rejectedNames = ["photo.heic"]
        let armed = FaultBox()
        let executor = makeExecutor(appBuild: "7") { [armed] in try armed.arm() }
        armed.executor = executor

        do {
            let report = try await executor.ensureBackedUp(localIdentifiers: ["photo"]) { _ in }
            XCTAssertEqual(report.backedUp, 0, "a run whose carry failed marks nothing done")
        } catch {
            XCTAssertEqual(error as? AlbumSyncError, .mappingStoreUnavailable)
        }
        XCTAssertEqual(armed.faults?.firedCount, 1, "the carry write ran and failed")
        XCTAssertNotEqual(try scratchRow()?.state, .completed)
        XCTAssertEqual(uploader.requests.count, 8, "one round runs without the stored rounds")
        XCTAssertEqual(try storedRounds(), 3, "a run that started without the rounds never replaces them")
        XCTAssertEqual(try storedEntry()?.roundBuild, "7")

        clock.advance(by: 3600)
        let before = uploader.requests.count
        _ = try await sync(appBuild: "7")
        XCTAssertEqual(uploader.requests.count, before, "the next run knows again that the photo stopped")
    }

    func testARunThatEndsBeforeTheCarryKeepsTheStoredRounds() async throws {
        try seedStoppedRefusal(roundBuild: "7")
        struct ScanEnded: Error {}

        do {
            _ = try await makeExecutor(appBuild: "7") { throw ScanEnded() }
                .ensureBackedUp(localIdentifiers: ["photo"]) { _ in }
            XCTFail("the scan ended the run")
        } catch {
            XCTAssertTrue(error is ScanEnded, "\(error)")
        }
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(try storedRounds(), 3, "the file keeps the rounds")

        _ = try await sync(appBuild: "7")
        XCTAssertTrue(uploader.requests.isEmpty, "the next run still knows that the photo stopped")
    }

    func testARefusalFileWriteThatFailsKeepsTheEarlierFileAndIsLogged() async throws {
        try seedStoppedRefusal(identifier: "another-album", roundBuild: "7")
        uploader.rejectedNames = ["photo.heic"]
        let failing = FailingReplace()

        _ = try await makeExecutor(appBuild: "7", refusalFileSystem: failing)
            .ensureBackedUp(localIdentifiers: ["photo"]) { _ in }

        XCTAssertEqual(failing.attempts, 1)
        XCTAssertNotNil(try storedEntry("another-album"), "the earlier file stays")
        XCTAssertNil(try storedEntry(), "this run's rounds are lost, which only costs retries")
        XCTAssertEqual(logLines.values, ["albumSync.refusalsNotSaved reason=write"])
    }

    // MARK: - An unknown read carries nothing

    func testAFileThatCannotBeReadCarriesNothingAndIsNotOverwritten() async throws {
        try seedStoppedRefusal(identifier: "another-album", roundBuild: "7")
        try seedStoppedRefusal(roundBuild: "7")
        // A file without read permission makes the read fail without proving the file absent.
        let path = refusalStore.url.path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        XCTAssertEqual(refusalStore.read(), .unknown(replaceable: false))
        uploader.rejectedNames = ["photo.heic"]

        _ = try await sync(appBuild: "7")

        XCTAssertEqual(uploader.requests.count, 8, "the run proceeds as without a carry")
        XCTAssertEqual(logLines.values, ["albumSync.refusalsNotSaved reason=unreadableFile"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        XCTAssertNotNil(try storedEntry("another-album"), "nothing replaces a file that a later read may still read")
        XCTAssertEqual(try storedRounds(), 3, "the stored rounds stay as they were")
    }

    func testAFileThatDoesNotDecodeIsReplacedOnlyByACompleteRun() async throws {
        try Data("{\"version\":2,\"entries\":[]}".utf8).write(to: refusalStore.url)
        XCTAssertEqual(refusalStore.read(), .unknown(replaceable: true), "a later format is not merged")
        uploader.rejectedNames = ["photo.heic"]

        _ = try await sync(appBuild: "7")

        XCTAssertEqual(uploader.requests.count, 8, "the run proceeds as without a carry")
        XCTAssertEqual(try storedRounds(), 1, "the run writes a complete file of its own")
        XCTAssertEqual(logLines.values, ["albumSync.refusalsReplaced"], "the replacement is logged")

        try Data("not json".utf8).write(to: refusalStore.url)
        XCTAssertEqual(refusalStore.read(), .unknown(replaceable: true))
    }

    func testAnUnknownRowReadEndsTheCarry() throws {
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        defer { queue.close() }
        let second = photoLibrarySource("second")
        for row in [source, second] {
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: row, revision: revision, originalFilename: "\(row.identifier).heic", byteCount: 4,
                        state: .discovered, updatedAt: clock.now)))
        }
        try seedStoppedRefusal(roundBuild: "7")
        try seedStoppedRefusal(identifier: "second", roundBuild: "7")
        let faults = try SQLiteStatementFaults(in: queue, failures: 1) {
            $0.hasPrefix("SELECT original_filename, byte_count, state")
        }
        // The trace must end before the queue closes.
        defer { faults.stop() }

        let carry = makeExecutor(appBuild: "7").carry(refusalStore.read(), into: queue)

        XCTAssertEqual(faults.firedCount, 1, "the first row read failed")
        XCTAssertTrue(carry.reached.isEmpty)
        XCTAssertFalse(carry.isComplete)
        XCTAssertEqual(logLines.values, ["albumSync.refusalsNotCarried reason=unknownRow"])
        let reader = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        defer { reader.close() }
        for row in [source, second] {
            let entry = try reader.entry(for: row, revision: revision)
            XCTAssertEqual(entry?.state, .discovered, row.identifier)
            XCTAssertNil(entry?.lastError, "an unknown row read ends the carry: \(row.identifier)")
        }
    }

    func testARowReadThatThrowsEndsTheCarry() throws {
        let manifest = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        defer { manifest.close() }
        XCTAssertTrue(
            manifest.upsert(
                UploadBackupSyncQueueEntry(
                    source: source, revision: revision, originalFilename: "photo.heic", byteCount: 4,
                    state: .discovered, updatedAt: clock.now)))
        try seedStoppedRefusal(roundBuild: "7")
        let queue = SpyQueueStore(inner: manifest, log: BackupEventLog())
        queue.entryReadFailure = CancellationError()

        let carry = makeExecutor(appBuild: "7").carry(refusalStore.read(), into: queue)

        XCTAssertTrue(carry.reached.isEmpty)
        XCTAssertFalse(carry.isComplete)
        XCTAssertEqual(logLines.values, ["albumSync.refusalsNotCarried reason=readError"])
        let entry = try manifest.entry(for: source, revision: revision)
        XCTAssertEqual(entry?.state, .discovered)
        XCTAssertNil(entry?.lastError, "a row read that throws ends the carry")
    }

    func testAFailedCarryWriteEndsTheCarry() throws {
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        defer { queue.close() }
        let second = photoLibrarySource("second")
        for row in [source, second] {
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: row, revision: revision, originalFilename: "\(row.identifier).heic", byteCount: 4,
                        state: .discovered, updatedAt: clock.now)))
        }
        try seedStoppedRefusal(roundBuild: "7")
        try seedStoppedRefusal(identifier: "second", roundBuild: "7")
        let faults = try SQLiteStatementFaults(in: queue, failures: 1) { $0.hasPrefix("UPDATE backup_sync_queue SET") }
        // The trace must end before the queue closes.
        defer { faults.stop() }

        let carry = makeExecutor(appBuild: "7").carry(refusalStore.read(), into: queue)

        XCTAssertEqual(faults.firedCount, 1, "the first write failed")
        XCTAssertTrue(carry.reached.isEmpty)
        XCTAssertFalse(carry.isComplete)
        XCTAssertEqual(logLines.values, ["albumSync.refusalsNotCarried reason=failedWrite"])
        let reader = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        defer { reader.close() }
        XCTAssertNil(try reader.entry(for: second, revision: revision)?.lastError, "a failed write ends the carry")
    }

    func testAFailedQueueReadAfterTheRunWritesNothingAndIsLogged() throws {
        try seedStoppedRefusal(roundBuild: "7")
        let before = try Data(contentsOf: refusalStore.url)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        defer { queue.close() }
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source, revision: revision, originalFilename: "photo.heic", byteCount: 4,
                    state: .completed, updatedAt: clock.now)))
        let faults = try SQLiteStatementFaults(in: queue, failures: 1) { $0.contains("FROM backup_sync_queue") }
        defer { faults.stop() }

        let executor = makeExecutor(appBuild: "7")
        let lookup = refusalStore.read()
        executor.writeBack(
            lookup, carry: executor.carry(.absent, into: queue), from: queue, localIdentifiers: ["photo"])

        XCTAssertEqual(faults.firedCount, 1)
        XCTAssertEqual(try Data(contentsOf: refusalStore.url), before, "the backed-up photo keeps its entry for now")
        XCTAssertEqual(logLines.values, ["albumSync.refusalsNotSaved reason=queueRead"])
    }

    func testAFileAboveTheSizeLimitReadsAsReplaceable() throws {
        // A valid file that only padding makes too large.
        var data = Data(#"{"version":1,"entries":[]}"#.utf8)
        data.append(Data(repeating: UInt8(ascii: " "), count: AlbumSyncRefusalStore.maximumFileSize))
        try data.write(to: refusalStore.url)
        XCTAssertEqual(refusalStore.read(), .unknown(replaceable: true))
    }

    // MARK: - Account removal

    func testSignOutRemovesTheRefusalFile() async throws {
        let base = tempDir.appendingPathComponent("libraries", isDirectory: true)
        let directory = LibraryDatabaseLocation.prepareAccountDirectory(uid: "account", in: base)
        uploader.rejectedNames = ["photo.heic"]
        _ = try await makeExecutor(accountDirectory: directory).ensureBackedUp(localIdentifiers: ["photo"]) { _ in }
        let file = AlbumSyncRefusalStore(accountDataDirectory: directory).url
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        XCTAssertTrue(LibraryDatabaseLocation.purgeAccountData(uid: "account", in: base))

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

/// Fails the carry's state write on the executor's new scratch queue once, armed when the scan starts.
private final class FaultBox: @unchecked Sendable {
    weak var executor: PhotoAlbumBackupExecutor?
    private let lock = NSLock()
    private var _faults: SQLiteStatementFaults?
    var faults: SQLiteStatementFaults? { lock.withLock { _faults } }

    func arm() throws {
        try lock.withLock {
            guard _faults == nil, let executor else { return }
            let runner = try XCTUnwrap(
                Mirror(reflecting: executor).children.first { $0.label == "activeRunner" }?.value as? BackupSyncRunner)
            let queue = try XCTUnwrap(
                Mirror(reflecting: runner).children.first { $0.label == "queue" }?.value
                    as? UploadBackupSyncQueueManifestStore)
            _faults = try SQLiteStatementFaults(in: queue, failures: 1) {
                $0.hasPrefix("UPDATE backup_sync_queue SET") && $0.contains("'failedPermanent'")
            }
        }
    }
}

/// A file system whose atomic replacement always fails.
private final class FailingReplace: DurableFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var attempts: Int { lock.withLock { count } }
    struct Failed: Error {}

    func replace(_ url: URL, with data: Data) throws {
        lock.withLock { count += 1 }
        throw Failed()
    }

    func openForAppending(_ url: URL) throws -> any DurableFileAppending { throw Failed() }
    func remove(_ url: URL) throws { throw Failed() }
    func synchronize(_ url: URL, isDirectory: Bool) throws {}
}
