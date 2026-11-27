import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

private struct PartialFailureCatalog: UploadBackupAssetCatalog {
    let candidate: UploadBackupAssetCandidate
    let error: FolderEnumerationError

    func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(candidate)
            continuation.finish(throwing: error)
        }
    }
}

/// Folder sync uses real temporary files, the SQLite queue, streaming hashing, and file resolution.
/// A file that vanishes during scan, check, or upload becomes `sourceMissing` without re-uploading.
final class FolderBackupIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var folder: URL!
    private var queueStore: UploadBackupSyncQueueManifestStore!
    private var preflight: UploadBackupPreflightIndex!
    private var engine: UploadBackupSyncEngine!
    private var checker: FakeChecker!
    private var pipeline: UploadDedupePipeline!
    private var uploader: MockUploader!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-backup-integration-\(UUID().uuidString)", isDirectory: true)
        folder = tempDir.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        queueStore = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
            ))
        preflight = UploadBackupPreflightIndex(store: MemoryBackupStateStore(removesRecords: false))
        engine = UploadBackupSyncEngine(preflight: preflight, queue: queueStore)
        checker = FakeChecker()
        pipeline = UploadDedupePipeline(store: FakeIdentityStore(), checker: checker)
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
    }

    override func tearDownWithError() throws {
        queueStore.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRunner(scope: ScopeBox? = nil) -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queueStore,
            preflight: preflight,
            resolver: scope.map { box in FileBackupResourceResolver(scope: { box.scope }) }
                ?? FileBackupResourceResolver(),
            identityResolver: pipeline,
            uploader: uploader
        )
    }

    /// The watched folders as the Mac app sees them now; a test changes them between passes.
    private final class ScopeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: WatchedFolderScope
        init(_ scope: WatchedFolderScope) { current = scope }
        var scope: WatchedFolderScope {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
    }

    private func receipt(for source: UploadSourceIdentity) -> UploadRemoteCommitReconciliation {
        UploadRemoteCommitReconciliation(
            source: source,
            identity: UploadIdentity(
                correctedName: "sent.jpg", nameHash: "name-hash", sha1Hex: String(repeating: "ab", count: 20),
                sha1Digest: Data(repeating: 0xAB, count: 20), contentHash: "content-hash"),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "link"))
    }

    /// Scans `new.jpg` and `sent.jpg`, and saves an upload receipt for `sent.jpg` as an upload that reached Proton
    /// before the app ended. Returns both rows as stored.
    private func queueNewAndSentFiles() async throws -> (
        new: UploadBackupSyncQueueEntry, sent: UploadBackupSyncQueueEntry
    ) {
        for name in ["new.jpg", "sent.jpg"] {
            try Data("bytes-\(name)".utf8).write(to: folder.appendingPathComponent(name))
        }
        _ = try await engine.scan(FolderBackupCatalog(folder: folder))
        let newSource = UploadSourceIdentity.file(folder.appendingPathComponent("new.jpg"))
        let sentSource = UploadSourceIdentity.file(folder.appendingPathComponent("sent.jpg"))
        let rows = try queueStore.decisionRows(
            kind: .fileURL, identifiers: [newSource.identifier, sentSource.identifier])
        XCTAssertEqual(rows.count, 2)
        let sentRow = try XCTUnwrap(rows.first { $0.source == sentSource })
        XCTAssertTrue(
            queueStore.markNeedsRemoteReconciliation(
                source: sentSource, revision: sentRow.revision, reconciliation: receipt(for: sentSource),
                lastError: nil, updatedAt: Date(timeIntervalSince1970: 100)))
        let newRow = try XCTUnwrap(rows.first { $0.source == newSource })
        return (
            try XCTUnwrap(queueStore.entry(for: newSource, revision: newRow.revision)),
            try XCTUnwrap(queueStore.entry(for: sentSource, revision: sentRow.revision))
        )
    }

    /// The drive of a watched folder is not mounted: its bookmark gave no path at launch, so the scope cannot place
    /// the files, and every path reads as missing. A pass keeps every row as it was, receipts included, burns no
    /// attempt and uploads nothing. Once the drive is back, the new file uploads once and the file with a receipt
    /// never uploads (#1583).
    func testAFolderOnADriveThatIsNotMountedKeepsItsRowsUntilTheDriveIsBack() async throws {
        let (new, sent) = try await queueNewAndSentFiles()
        let away = tempDir.appendingPathComponent("Unmounted", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: away)
        let scope = ScopeBox(WatchedFolderScope(readable: [], registered: ["?"]))

        _ = await makeRunner(scope: scope).runUntilDrained()

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(try queueStore.entry(for: new.source, revision: new.revision), new)
        XCTAssertEqual(try queueStore.entry(for: sent.source, revision: sent.revision), sent)

        try FileManager.default.moveItem(at: away, to: folder)
        scope.scope = WatchedFolderScope(readable: [folder], registered: [folder.path])
        _ = await makeRunner(scope: scope).runUntilDrained()

        XCTAssertEqual(uploader.requests.map(\.name), ["new.jpg"], "the file with a receipt never uploads again")
        XCTAssertEqual(try queueStore.entry(for: new.source, revision: new.revision)?.state, .completed)
        let settled = try XCTUnwrap(try queueStore.entry(for: sent.source, revision: sent.revision))
        XCTAssertTrue(
            settled.state.isTerminalSuccess || settled.remoteCommitReconciliation == sent.remoteCommitReconciliation,
            "the receipt is settled or still kept: \(settled.state)")
    }

    /// The drive goes away while its folder is still open: the folder itself is gone, so a missing file in it is no
    /// proof that the file was deleted (#1583).
    func testAFolderWhoseDriveGoesAwayDuringAPassKeepsItsRows() async throws {
        let (new, sent) = try await queueNewAndSentFiles()
        let scope = ScopeBox(WatchedFolderScope(readable: [folder], registered: [folder.path]))
        try FileManager.default.moveItem(at: folder, to: tempDir.appendingPathComponent("Unmounted", isDirectory: true))

        _ = await makeRunner(scope: scope).runUntilDrained()

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(try queueStore.entry(for: new.source, revision: new.revision), new)
        XCTAssertEqual(try queueStore.entry(for: sent.source, revision: sent.revision), sent)
    }

    /// A file that was deleted from a folder that is still there leaves the queue, as before. A file with a saved
    /// upload receipt keeps its row and its receipt (#1583).
    func testADeletedFileLeavesTheQueueButAFileWithAReceiptKeepsIt() async throws {
        let (new, sent) = try await queueNewAndSentFiles()
        let scope = ScopeBox(WatchedFolderScope(readable: [folder], registered: [folder.path]))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("new.jpg"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("sent.jpg"))

        _ = await makeRunner(scope: scope).runUntilDrained()

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertNil(try queueStore.entry(for: new.source, revision: new.revision))
        let kept = try XCTUnwrap(try queueStore.entry(for: sent.source, revision: sent.revision))
        XCTAssertEqual(kept.state, .needsRemoteReconciliation)
        XCTAssertEqual(kept.remoteCommitReconciliation, sent.remoteCommitReconciliation)
    }

    func testScanRunRescanBacksUpOnceAndOnlyOnce() async throws {
        for name in ["IMG_0001.jpg", "IMG_0002.heic", "clip.mov"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }

        // First pass: everything is new, everything uploads exactly once.
        let firstScan = try await engine.scan(FolderBackupCatalog(folder: folder))
        XCTAssertEqual(firstScan.scanned, 3)
        XCTAssertEqual(firstScan.queuedForWork, 3)

        let firstRun = await makeRunner().runUntilDrained()
        XCTAssertEqual(firstRun.uploaded, 3)
        XCTAssertEqual(firstRun.backedUp, 3)
        XCTAssertEqual(firstRun.fraction, 1.0)
        XCTAssertEqual(Set(uploader.requests.map(\.name)), ["IMG_0001.jpg", "IMG_0002.heic", "clip.mov"])
        XCTAssertTrue(
            uploader.requests.allSatisfy { $0.expectedSHA1 != nil },
            "backup uploads must carry the integrity digest from the shared pipeline")

        // Second pass: the preflight index proves everything backed up without touching bytes.
        let secondScan = try await engine.scan(FolderBackupCatalog(folder: folder))
        XCTAssertEqual(secondScan.alreadyBackedUp, 3)
        XCTAssertEqual(secondScan.queuedForWork, 0)

        let secondRun = await makeRunner().runUntilDrained()
        XCTAssertEqual(uploader.requests.count, 3, "a repeat sync must never re-upload")
        XCTAssertEqual(secondRun.backedUp, 3)
        XCTAssertEqual(secondRun.hasOutstandingWork, false)
    }

    /// Identical content in copied folders uploads once and records every source as backed up.
    func testCopiedFoldersUploadEachContentOnlyOnce() async throws {
        let sync1 = tempDir.appendingPathComponent("sync1", isDirectory: true)
        let sync2 = tempDir.appendingPathComponent("sync2", isDirectory: true)
        try FileManager.default.createDirectory(at: sync1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sync2, withIntermediateDirectories: true)
        for name in ["IMG_0001.jpg", "IMG_0002.heic", "clip.mov"] {
            let bytes = Data("photo-bytes-\(name)".utf8)
            try bytes.write(to: sync1.appendingPathComponent(name))
            try bytes.write(to: sync2.appendingPathComponent(name))
        }

        _ = try await engine.scan(FolderBackupCatalog(folder: sync1))
        _ = try await engine.scan(FolderBackupCatalog(folder: sync2))
        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(
            uploader.requests.count, 3,
            "a byte-identical copied folder must not re-upload a single photo")
        XCTAssertEqual(progress.uploaded, 3)
        XCTAssertEqual(progress.alreadyBackedUp, 3)
        XCTAssertEqual(progress.backedUp, 6, "BOTH folders' sources must be proven backed up")
        XCTAssertEqual(progress.failed + progress.sourceMissing + progress.blocked, 0)

        // A third copy attached later: zero new uploads, everything already backed up.
        let sync3 = tempDir.appendingPathComponent("sync3", isDirectory: true)
        try FileManager.default.createDirectory(at: sync3, withIntermediateDirectories: true)
        for name in ["IMG_0001.jpg", "IMG_0002.heic", "clip.mov"] {
            try Data("photo-bytes-\(name)".utf8).write(to: sync3.appendingPathComponent(name))
        }
        _ = try await engine.scan(FolderBackupCatalog(folder: sync3))
        let third = await makeRunner().runUntilDrained()

        XCTAssertEqual(uploader.requests.count, 3, "a later copied folder must upload nothing new")
        XCTAssertEqual(third.backedUp, 9)
    }

    func testCopiedContentWithDifferentFilenamesUploadsOnce() async throws {
        let sync1 = tempDir.appendingPathComponent("sync1", isDirectory: true)
        let sync2 = tempDir.appendingPathComponent("sync2", isDirectory: true)
        try FileManager.default.createDirectory(at: sync1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sync2, withIntermediateDirectories: true)
        let bytes = Data("the-same-photo-bytes".utf8)
        try bytes.write(to: sync1.appendingPathComponent("IMG_0001.jpg"))
        try bytes.write(to: sync2.appendingPathComponent("export (1).jpg"))

        _ = try await engine.scan(FolderBackupCatalog(folder: sync1))
        _ = try await engine.scan(FolderBackupCatalog(folder: sync2))
        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(
            uploader.requests.count, 1,
            "identical bytes must dedupe even when the filename differs")
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(progress.alreadyBackedUp, 1)
        XCTAssertEqual(progress.backedUp, 2)
    }

    func testFileDeletedBetweenScanAndRunIsRemovedFromQueue() async throws {
        let doomed = folder.appendingPathComponent("gone.jpg")
        try Data("bytes".utf8).write(to: doomed)

        _ = try await engine.scan(FolderBackupCatalog(folder: folder))
        try FileManager.default.removeItem(at: doomed)

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(progress.sourceMissing, 0)
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(queueStore.count(), 0)
    }

    func testPartialEnumerationFailurePreservesQueuedPrefix() async throws {
        let firstURL = folder.appendingPathComponent("a-first.jpg")
        try Data("first".utf8).write(to: firstURL)
        let candidate = try FolderBackupCatalog.candidate(for: firstURL)
        let inaccessibleSubtree = folder.appendingPathComponent("z-inaccessible", isDirectory: true)
        let error = FolderEnumerationError(
            operation: .readDirectory,
            url: inaccessibleSubtree,
            failureClass: .permissionDenied,
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.EACCES.rawValue)
        )

        do {
            _ = try await engine.scan(PartialFailureCatalog(candidate: candidate, error: error))
            XCTFail("a partial folder enumeration must not report a successful scan")
        } catch let caught as FolderEnumerationError {
            XCTAssertEqual(caught, error)
        }

        let summary = queueStore.summary()!
        XCTAssertEqual(summary.total, 1)
        XCTAssertEqual(summary.waiting, 1)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.alreadyBackedUp, 0)
        XCTAssertEqual(summary.uploaded, 0)
    }
}
