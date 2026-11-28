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
    private var trail: SupportEventTrail!
    /// The resolver of the last runner that `makeRunner(scope:)` made.
    private var reads: CountingResolver!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-backup-integration-\(UUID().uuidString)", isDirectory: true)
        folder = tempDir.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        trail = SupportEventTrail()
        queueStore = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName),
                supportTrail: trail
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

    /// `usesClaimFilter: false` makes a runner whose claims take every row, as if the claim filter and the read of a
    /// file disagreed.
    private func makeRunner(scope: ScopeBox? = nil, usesClaimFilter: Bool = true) -> BackupSyncRunner {
        guard let scope else { return makeRunner(resolver: FileBackupResourceResolver()) }
        reads = CountingResolver(
            inner: FileBackupResourceResolver(scope: { scope.scope }), usesClaimFilter: usesClaimFilter)
        return makeRunner(resolver: reads)
    }

    private func makeRunner(
        resolver: any BackupResourceResolving, uploader: (any PhotoUploading)? = nil
    ) -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queueStore,
            preflight: preflight,
            resolver: resolver,
            identityResolver: pipeline,
            uploader: uploader ?? self.uploader
        )
    }

    /// Runs `beforeUpload`, a drive that is unplugged during the upload, and then fails the upload with the error of a
    /// file read that found no file.
    private struct UnpluggingUploader: PhotoUploading {
        let inner: MockUploader
        let beforeUpload: @Sendable () -> Void

        var capabilities: UploadBackendCapabilities { inner.capabilities }

        func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
            try await inner.reserveNetwork(allowsExpensiveNetwork: allowsExpensiveNetwork)
        }

        func upload(
            _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
        ) async throws -> PhotoUID {
            beforeUpload()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }

        func cancel(token: UUID) async { await inner.cancel(token: token) }

        func ensureRemoteCapacity(forBytes bytes: Int64, filename: String) async throws {
            try await inner.ensureRemoteCapacity(forBytes: bytes, filename: filename)
        }
    }

    /// Counts the reads of each file. A second read of a file in the same pass finds it deleted, so a pass that reads a
    /// waiting file again loses its row.
    private final class CountingResolver: BackupResourceResolving, @unchecked Sendable {
        private let inner: FileBackupResourceResolver
        private let usesClaimFilter: Bool
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        init(inner: FileBackupResourceResolver, usesClaimFilter: Bool) {
            self.inner = inner
            self.usesClaimFilter = usesClaimFilter
        }

        func reads(of source: UploadSourceIdentity) -> Int { lock.withLock { counts[source.identifier, default: 0] } }

        func fileClaimFilter() -> BackupFileClaimFilter? { usesClaimFilter ? inner.fileClaimFilter() : nil }

        func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
            let count = lock.withLock { () -> Int in
                counts[entry.source.identifier, default: 0] += 1
                return counts[entry.source.identifier, default: 0]
            }
            guard count == 1 else { return nil }
            return try await inner.resolve(entry)
        }
    }

    /// Runs one pass. A pass that does not end within `seconds`, for example one that keeps waking for a row that no
    /// claim may take, fails the test and is cancelled.
    private func runBounded(_ runner: BackupSyncRunner, seconds: TimeInterval = 15) async {
        let ended = PassEnd()
        let pass = Task {
            await runner.runUntilDrained()
            ended.mark()
        }
        let deadline = Date().addingTimeInterval(seconds)
        while !ended.value, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        if !ended.value {
            XCTFail("the pass did not end")
            // Only a cancelled task ends an idle wait; `stop()` holds back new starts.
            pass.cancel()
        }
        await pass.value
    }

    private final class PassEnd: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false
        var value: Bool { lock.withLock { ended } }
        func mark() { lock.withLock { ended = true } }
    }

    /// Reads a file, then runs `afterRead` once: a drive that is unplugged, or a file that is deleted, after the read
    /// and before the hash.
    private struct AfterReadResolver: BackupResourceResolving {
        let inner: FileBackupResourceResolver
        let afterRead: @Sendable () -> Void

        func fileClaimFilter() -> BackupFileClaimFilter? { inner.fileClaimFilter() }

        func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
            let resolved = try await inner.resolve(entry)
            afterRead()
            return resolved
        }
    }

    /// The scope as the Mac app derives it from its folder list: it holds access to every folder that it may read.
    private func registryScope(_ registry: WatchedFolderRegistry) -> WatchedFolderScope {
        registry.scope(readable: registry.readableFolders.compactMap { $0.path.map(URL.init(fileURLWithPath:)) })
    }

    /// The kind and time of each support trail event of the files in `sources`. Each export salts the subjects anew.
    private func trailEvents(of sources: [UploadSourceIdentity]) -> [String] {
        let hasher = SupportReportIdentifierHasher()
        let subjects = Set(sources.map { hasher.hash($0.identifier) })
        return trail.export(hashingWith: hasher).events
            .filter { $0.subject.map(subjects.contains) == true }
            .map { "\($0.kind) \($0.time.timeIntervalSince1970)" }
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
    /// attempt and uploads nothing. The drive is mounted while the app runs: the next pass resolves the bookmark again
    /// as the app does before its claims, and then the waiting file and a new file of the drive upload once, and the
    /// file with a receipt never uploads (#1583).
    func testAFolderOnADriveThatIsNotMountedKeepsItsRowsUntilTheDriveIsBack() async throws {
        let (new, sent) = try await queueNewAndSentFiles()
        let away = tempDir.appendingPathComponent("Unmounted", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: away)
        let bookmark = Data("folder".utf8)
        var registry = WatchedFolderRegistry(savedBookmarks: [bookmark]) { _ in .unresolved }
        let scope = ScopeBox(registryScope(registry))
        let trailBefore = trailEvents(of: [new.source, sent.source])

        await runBounded(makeRunner(scope: scope))

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(try queueStore.entry(for: new.source, revision: new.revision), new)
        XCTAssertEqual(try queueStore.entry(for: sent.source, revision: sent.revision), sent)
        XCTAssertEqual([reads.reads(of: new.source), reads.reads(of: sent.source)], [0, 0], "no claim takes them")
        XCTAssertEqual(trailEvents(of: [new.source, sent.source]), trailBefore)

        try FileManager.default.moveItem(at: away, to: folder)
        try Data("later".utf8).write(to: folder.appendingPathComponent("later.jpg"))
        XCTAssertTrue(registry.refresh { _ in .resolved(path: self.folder.path, isStale: false) })
        scope.scope = registryScope(registry)
        _ = try await engine.scan(FolderBackupCatalog(folder: folder))
        await runBounded(makeRunner(scope: scope))

        XCTAssertEqual(
            uploader.requests.map(\.name).sorted(), ["later.jpg", "new.jpg"],
            "the file with a receipt never uploads again")
        XCTAssertEqual(try queueStore.entry(for: new.source, revision: new.revision)?.state, .completed)
        let settled = try XCTUnwrap(try queueStore.entry(for: sent.source, revision: sent.revision))
        XCTAssertTrue(
            settled.state.isTerminalSuccess || settled.remoteCommitReconciliation == sent.remoteCommitReconciliation,
            "the receipt is settled or still kept: \(settled.state)")
    }

    /// The drive is unplugged before a pass: its scan cannot resolve the bookmark and marks the folder, as the app does,
    /// and the pass leaves the rows alone. Plugged in again, the next pass resolves the bookmark before its claims and
    /// backs up the waiting file and a new one (#1583).
    func testAFolderUnpluggedForAPassBacksUpOnceItIsPluggedInAgain() async throws {
        let (new, sent) = try await queueNewAndSentFiles()
        let bookmark = Data("folder".utf8)
        var registry = WatchedFolderRegistry(savedBookmarks: [bookmark]) { _ in
            .resolved(path: self.folder.path, isStale: false)
        }
        let id = try XCTUnwrap(registry.folders.first?.id)
        let away = tempDir.appendingPathComponent("Unplugged", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: away)
        XCTAssertTrue(registry.apply(.unresolved, to: id))
        let scope = ScopeBox(registryScope(registry))

        await runBounded(makeRunner(scope: scope))

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(try queueStore.entry(for: new.source, revision: new.revision), new)
        XCTAssertEqual(try queueStore.entry(for: sent.source, revision: sent.revision), sent)
        XCTAssertEqual([reads.reads(of: new.source), reads.reads(of: sent.source)], [0, 0])

        try FileManager.default.moveItem(at: away, to: folder)
        try Data("later".utf8).write(to: folder.appendingPathComponent("later.jpg"))
        XCTAssertTrue(registry.refresh { _ in .resolved(path: self.folder.path, isStale: false) })
        scope.scope = registryScope(registry)
        _ = try await engine.scan(FolderBackupCatalog(folder: folder))
        await runBounded(makeRunner(scope: scope))

        XCTAssertEqual(uploader.requests.map(\.name).sorted(), ["later.jpg", "new.jpg"])
    }

    /// The drive goes away while its folder is still open: the folder itself is gone, so a missing file in it is no
    /// proof that the file was deleted, and the pass does not take its rows (#1583).
    func testAFolderWhoseDriveGoesAwayDuringAPassKeepsItsRows() async throws {
        let (new, sent) = try await queueNewAndSentFiles()
        let scope = ScopeBox(WatchedFolderScope(readable: [folder], registered: [folder.path]))
        try FileManager.default.moveItem(at: folder, to: tempDir.appendingPathComponent("Unmounted", isDirectory: true))

        await runBounded(makeRunner(scope: scope))

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(try queueStore.entry(for: new.source, revision: new.revision), new)
        XCTAssertEqual(try queueStore.entry(for: sent.source, revision: sent.revision), sent)
        XCTAssertEqual([reads.reads(of: new.source), reads.reads(of: sent.source)], [0, 0], "no claim takes them")
    }

    /// The drive goes away after the claim, before the read: the read refuses the file, and the row returns exactly
    /// as it was stored, receipt included, without a support trail event. The pass does not read it again (#1583).
    func testAFileWhoseFolderGoesAwayAfterItsClaimIsReadOnceAndKeptAsStored() async throws {
        let (new, sent) = try await queueNewAndSentFiles()
        let scope = ScopeBox(WatchedFolderScope(readable: [folder], registered: [folder.path]))
        let away = tempDir.appendingPathComponent("Unmounted", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: away)
        let trailBefore = trailEvents(of: [new.source, sent.source])

        await runBounded(makeRunner(scope: scope, usesClaimFilter: false))

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual([reads.reads(of: new.source), reads.reads(of: sent.source)], [1, 1])
        XCTAssertEqual(try queueStore.entry(for: new.source, revision: new.revision), new)
        XCTAssertEqual(try queueStore.entry(for: sent.source, revision: sent.revision), sent)
        XCTAssertEqual(trailEvents(of: [new.source, sent.source]), trailBefore)

        // The same after a launch that found no path for the folder, and for a folder that is there but that the app
        // may not read now: its files are not read.
        for current in [
            WatchedFolderScope(readable: [], registered: ["?"]),
            WatchedFolderScope(readable: [], registered: [folder.path]),
        ] {
            if current.registeredRoots != nil { try FileManager.default.moveItem(at: away, to: folder) }
            scope.scope = current
            await runBounded(makeRunner(scope: scope, usesClaimFilter: false))

            XCTAssertTrue(uploader.requests.isEmpty)
            XCTAssertEqual([reads.reads(of: new.source), reads.reads(of: sent.source)], [1, 1])
            XCTAssertEqual(try queueStore.entry(for: new.source, revision: new.revision), new)
            XCTAssertEqual(try queueStore.entry(for: sent.source, revision: sent.revision), sent)
            XCTAssertEqual(trailEvents(of: [new.source, sent.source]), trailBefore)
        }
    }

    /// The folder list changes between the check before the read and the missing file, for example because a scan found
    /// the drive gone: the missing file proves nothing then (#1583).
    func testAMissingFileCountsAsDeletedOnlyWhileItsFolderIsStillReachable() async throws {
        let gone = tempDir.appendingPathComponent("Gone", isDirectory: true)
        let source = UploadSourceIdentity.file(gone.appendingPathComponent("IMG.jpg"))
        let entry = UploadBackupSyncQueueEntry(
            source: source, revision: UploadBackupRevision(rawValue: 1), originalFilename: "IMG.jpg",
            updatedAt: Date(timeIntervalSince1970: 100))
        let checks = PassEnd()
        let resolver = FileBackupResourceResolver(scope: {
            defer { checks.mark() }
            // First the folder is no registered folder, then it is a readable folder whose drive is gone.
            return checks.value
                ? WatchedFolderScope(readable: [gone], registered: [gone.path])
                : WatchedFolderScope(readable: [], registered: [])
        })

        do {
            _ = try await resolver.resolve(entry)
            XCTFail("the missing file proves nothing while its folder is gone")
        } catch is BackupSourceLocationUnavailableError {}
    }

    /// The drive is unplugged after the read of a file and before its hash: the missing file proves nothing while its
    /// folder is gone, so the row returns as it was stored. A file that is deleted at the same point while its folder
    /// stays leaves the queue, as in 1.1.0 (#1583).
    func testAFileThatGoesMissingWhileItIsHashedLeavesTheQueueOnlyWhileItsFolderIsThere() async throws {
        let file = folder.appendingPathComponent("hashed.jpg")
        let scope = WatchedFolderScope(readable: [folder], registered: [folder.path])
        let away = tempDir.appendingPathComponent("Unplugged", isDirectory: true)
        for unplugs in [true, false] {
            try Data("hashed".utf8).write(to: file)
            _ = try await engine.scan(FolderBackupCatalog(folder: folder))
            let source = UploadSourceIdentity.file(file)
            let row = try XCTUnwrap(
                try queueStore.decisionRows(kind: .fileURL, identifiers: [source.identifier]).first)
            let stored = try XCTUnwrap(try queueStore.entry(for: source, revision: row.revision))
            let folder = self.folder!
            let resolver = AfterReadResolver(inner: FileBackupResourceResolver(scope: { scope })) {
                if unplugs {
                    try? FileManager.default.moveItem(at: folder, to: away)
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }

            await runBounded(makeRunner(resolver: resolver))

            XCTAssertTrue(uploader.requests.isEmpty)
            if unplugs {
                XCTAssertEqual(try queueStore.entry(for: source, revision: stored.revision), stored)
                try FileManager.default.moveItem(at: away, to: folder)
                try FileManager.default.removeItem(at: file)
                XCTAssertTrue(queueStore.remove(source: source, revision: stored.revision))
            } else {
                XCTAssertNil(try queueStore.entry(for: source, revision: stored.revision))
            }
        }
    }

    /// The drive is unplugged during the upload, a later state of the run than its claim: the row returns as stored
    /// (#1583).
    func testAFileWhoseDriveGoesAwayDuringItsUploadKeepsItsRow() async throws {
        let file = folder.appendingPathComponent("uploading.jpg")
        try Data("uploading".utf8).write(to: file)
        _ = try await engine.scan(FolderBackupCatalog(folder: folder))
        let source = UploadSourceIdentity.file(file)
        let row = try XCTUnwrap(try queueStore.decisionRows(kind: .fileURL, identifiers: [source.identifier]).first)
        let stored = try XCTUnwrap(try queueStore.entry(for: source, revision: row.revision))
        let scope = WatchedFolderScope(readable: [folder], registered: [folder.path])
        let folder = self.folder!
        let away = tempDir.appendingPathComponent("Unplugged", isDirectory: true)
        let unplugging = UnpluggingUploader(inner: uploader) { try? FileManager.default.moveItem(at: folder, to: away) }

        await runBounded(makeRunner(resolver: FileBackupResourceResolver(scope: { scope }), uploader: unplugging))

        XCTAssertEqual(try queueStore.entry(for: source, revision: stored.revision), stored)
    }

    /// A read error counts as a local one, and so as a reason to check the folder, only when the file system answered;
    /// a cancellation goes its own way (#1583).
    func testOnlyAFileSystemErrorCountsAsALocalReadFailure() {
        XCTAssertTrue(BackupSyncRunner.isLocalReadFailure(UploadError.fileMissing("IMG.jpg")))
        XCTAssertTrue(BackupSyncRunner.isLocalReadFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        XCTAssertTrue(
            BackupSyncRunner.isLocalReadFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
        XCTAssertFalse(
            BackupSyncRunner.isLocalReadFailure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        XCTAssertFalse(BackupSyncRunner.isLocalReadFailure(UploadError.backend("transient")))
    }

    /// The drive is mounted under another name ("Photos 1"): the reconcile keeps the rows of the old path, receipts
    /// included, and the pass does not take them; they leave the queue when the person removes the folder and every
    /// folder is known (#1583).
    func testADriveMountedUnderAnotherNameKeepsTheRowsOfItsEarlierPath() async throws {
        let (new, sent) = try await queueNewAndSentFiles()
        let oldPath = folder.path
        let renamed = tempDir.appendingPathComponent("Photos 1", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)
        let bookmark = Data("folder".utf8)
        var registry = WatchedFolderRegistry(savedBookmarks: [bookmark]) { _ in
            .resolved(path: oldPath, isStale: false)
        }
        let id = try XCTUnwrap(registry.folders.first?.id)
        XCTAssertTrue(registry.refresh(resolve: { _ in .resolved(path: renamed.path, isStale: false) }))
        let scope = ScopeBox(registryScope(registry))

        XCTAssertEqual(queueStore.removeFileSources(outside: scope.scope), 0)
        await runBounded(makeRunner(scope: scope))

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(try queueStore.entry(for: new.source, revision: new.revision), new)
        XCTAssertEqual(try queueStore.entry(for: sent.source, revision: sent.revision), sent)
        XCTAssertEqual([reads.reads(of: new.source), reads.reads(of: sent.source)], [0, 0])

        registry.remove(id)
        XCTAssertEqual(queueStore.removeFileSources(outside: registryScope(registry)), 2)
        XCTAssertNil(try queueStore.entry(for: sent.source, revision: sent.revision))
    }

    /// A launch found the drive under another name ("Photos 1") and queued its files there; the next launch finds it
    /// under its first name again. The saved paths keep the rows of "Photos 1", receipts included, also after the person
    /// adds the folder again and the app starts once more; they leave the queue when the person removes the folder
    /// (#1583).
    func testTheRowsOfAnEarlierPathOutliveARelaunchAndLeaveWithTheFolder() async throws {
        let (new, sent) = try await queueNewAndSentFiles()
        let firstName = tempDir.appendingPathComponent("Original", isDirectory: true)
        let bookmark = Data("folder".utf8)
        let launch = WatchedFolderRegistry(
            savedBookmarks: [bookmark], resolve: { _ in .resolved(path: self.folder.path, isStale: false) },
            lastKnownPath: { _ in firstName.path })
        XCTAssertTrue(launch.pathsNeedSaving(comparedTo: nil))
        let savedAtLaunch = launch.pathsToSave
        try FileManager.default.moveItem(at: folder, to: firstName)

        var relaunch = WatchedFolderRegistry(
            savedBookmarks: launch.bookmarks, savedPaths: savedAtLaunch,
            resolve: { _ in .resolved(path: firstName.path, isStale: false) }, lastKnownPath: { _ in firstName.path })

        XCTAssertEqual(queueStore.removeFileSources(outside: registryScope(relaunch)), 0)
        XCTAssertEqual(try queueStore.entry(for: new.source, revision: new.revision), new)
        XCTAssertEqual(try queueStore.entry(for: sent.source, revision: sent.revision), sent)

        let addedAgain = Data("folder again".utf8)
        relaunch.add(bookmark: addedAgain, path: firstName.path, lastKnownPath: { _ in nil })
        XCTAssertEqual(queueStore.removeFileSources(outside: registryScope(relaunch)), 0)
        let third = WatchedFolderRegistry(
            savedBookmarks: relaunch.bookmarks, savedPaths: relaunch.pathsToSave,
            resolve: { _ in .resolved(path: firstName.path, isStale: false) }, lastKnownPath: { _ in nil })
        XCTAssertEqual(queueStore.removeFileSources(outside: registryScope(third)), 0)
        XCTAssertEqual(try queueStore.entry(for: sent.source, revision: sent.revision), sent)

        var removed = third
        removed.remove(try XCTUnwrap(removed.folders.first?.id))
        XCTAssertEqual(removed.pathsToSave, [:])
        XCTAssertEqual(queueStore.removeFileSources(outside: registryScope(removed)), 2)
        XCTAssertNil(try queueStore.entry(for: sent.source, revision: sent.revision))
        XCTAssertNil(try queueStore.entry(for: new.source, revision: new.revision))
    }

    /// A row of a drive that is away sets no time in the waiting status: its wait ends only when the drive is back
    /// (#1583).
    func testARowOfADriveThatIsAwaySetsNoTimeInTheWaitingStatus() async throws {
        let driveRow = UploadBackupSyncQueueEntry(
            source: .file(URL(fileURLWithPath: "/Volumes/Away-1583/IMG_1.jpg")),
            revision: UploadBackupRevision(rawValue: 1),
            originalFilename: "IMG_1.jpg",
            lastError: BackupIssueRecord(
                kind: .network, detail: "drive", nextAttemptAt: Date(timeIntervalSince1970: 1_000)
            ).persistedValue,
            updatedAt: Date(timeIntervalSince1970: 1_000))
        var diskRow = driveRow
        diskRow.source = .file(folder.appendingPathComponent("IMG_2.jpg"))
        diskRow.lastError =
            BackupIssueRecord(
                kind: .network, detail: "disk", nextAttemptAt: Date(timeIntervalSince1970: 2_000)
            ).persistedValue
        diskRow.updatedAt = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(queueStore.upsertBatch([driveRow, diskRow]))
        let scope = WatchedFolderScope(readable: [folder], registered: [folder.path, "?"])

        let filter: @Sendable () -> BackupFileClaimFilter? = { scope.claimFilter() }
        let queue: UploadBackupSyncQueueManifestStore = queueStore
        func nextAttempt(filtered: Bool) async throws -> Date? {
            let projector = BackupStatusProjector(queue: queue, fileClaimFilter: filtered ? filter : nil)
            let generation = UUID()
            await projector.start(generation: generation, context: .init(), handler: { _ in })
            let projected = await projector.projectNow(context: .init(), generation: generation, revision: 1)
            let projection = try XCTUnwrap(projected)
            await projector.stop()
            return projection.progress.outstanding.nextAttemptAt
        }

        let unfiltered = try await nextAttempt(filtered: false)
        let filtered = try await nextAttempt(filtered: true)
        XCTAssertEqual(unfiltered, Date(timeIntervalSince1970: 1_000), "the fixture holds the earlier row of the drive")
        XCTAssertEqual(filtered, Date(timeIntervalSince1970: 2_000))
    }

    /// More waiting rows of a drive that is away than a pass may set aside (64) plus one full claim (32), all newer than
    /// a file of a readable folder: the pass takes none of them, sends none of their names to Proton, backs up the
    /// readable file and ends. Once the drive is back, its files back up (#1583).
    func testRowsOfADriveThatIsAwayNeitherHoldBackNorStarveAReadableFolder() async throws {
        let older = folder.appendingPathComponent("older.jpg")
        try Data("older".utf8).write(to: older)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: older.path)
        let drive = tempDir.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let driveFiles = (0..<100).map { drive.appendingPathComponent("drive-\($0).jpg") }
        for (index, file) in driveFiles.enumerated() {
            try Data("drive-\(index)".utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 2_000_000 + Double(index))], ofItemAtPath: file.path)
        }
        _ = try await engine.scan(FolderBackupCatalog(folder: folder))
        _ = try await engine.scan(FolderBackupCatalog(folder: drive))
        let driveSources = driveFiles.map { UploadSourceIdentity.file($0) }
        let stored = try queueStore.decisionRows(kind: .fileURL, identifiers: Set(driveSources.map(\.identifier)))
            .map { try XCTUnwrap(try queueStore.entry(for: $0.source, revision: $0.revision)) }
        XCTAssertEqual(stored.count, 100)
        let away = tempDir.appendingPathComponent("Unmounted", isDirectory: true)
        try FileManager.default.moveItem(at: drive, to: away)
        let scope = ScopeBox(WatchedFolderScope(readable: [folder], registered: [folder.path, "?"]))

        await runBounded(makeRunner(scope: scope))

        XCTAssertEqual(uploader.requests.map(\.name), ["older.jpg"])
        XCTAssertEqual(
            Set(checker.findBatches.joined()).count, 1,
            "only the name of the readable file goes to the duplicate check")
        for row in stored {
            XCTAssertEqual(try queueStore.entry(for: row.source, revision: row.revision), row)
        }
        XCTAssertEqual(trailEvents(of: driveSources), [])

        try FileManager.default.moveItem(at: away, to: drive)
        scope.scope = WatchedFolderScope(readable: [folder, drive], registered: [folder.path, drive.path])
        await runBounded(makeRunner(scope: scope))

        XCTAssertEqual(
            Set(uploader.requests.map(\.name)), Set(["older.jpg"] + driveFiles.map { $0.lastPathComponent }))
        XCTAssertEqual(uploader.requests.count, 101)
        for row in stored {
            XCTAssertEqual(try queueStore.entry(for: row.source, revision: row.revision)?.state, .completed)
        }
    }

    /// A file that was deleted from a folder that is still there leaves the queue, as in 1.1.0, also with a saved upload
    /// receipt: the item already exists in Proton, and the receipt cannot settle without the file (#1583).
    func testADeletedFileLeavesTheQueueWithItsReceiptAsBefore() async throws {
        let (new, sent) = try await queueNewAndSentFiles()
        let scope = ScopeBox(WatchedFolderScope(readable: [folder], registered: [folder.path]))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("new.jpg"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("sent.jpg"))

        await runBounded(makeRunner(scope: scope))

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertNil(try queueStore.entry(for: new.source, revision: new.revision))
        XCTAssertNil(try queueStore.entry(for: sent.source, revision: sent.revision))
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
