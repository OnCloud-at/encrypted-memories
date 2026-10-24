import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// A saved upload receipt settles only the revision it was saved for. A source that changed after the remote commit
/// takes the ordinary path, so its new bytes are hashed, deduplicated and uploaded on their own.
final class BackupReceiptRevisionTests: XCTestCase {
    private var tempDir: URL!
    private var clock: BackupTestClock!
    private var queueStore: UploadBackupSyncQueueManifestStore!
    private var preflight: UploadBackupPreflightIndex!
    private var identityStore: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var resolver: ScriptedBackupResolver!
    private var uploader: MockUploader!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-receipt-revision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = BackupTestClock()
        queueStore = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        preflight = UploadBackupPreflightIndex(store: MemoryStateStore(), now: { [clock] in clock!.now })
        identityStore = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        resolver = ScriptedBackupResolver(defaultModified: clock.now.addingTimeInterval(-3600))
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
        // A new upload of the same name gets its own Proton link, as on the server.
        uploader.distinctNodesForRepeatedNames = true
    }

    override func tearDownWithError() throws {
        queueStore.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - The comparison that every source kind goes through

    func testAReceiptBelongsOnlyToTheRevisionItWasSavedFor() throws {
        for kind in [UploadSourceIdentity.Kind.fileURL, .photoLibraryAsset] {
            let entry = UploadBackupSyncQueueEntry(
                source: UploadSourceIdentity(kind: kind, identifier: "/backup/photo.jpg"), revision: revision(10),
                originalFilename: "photo.jpg", byteCount: 4, updatedAt: clock.now)
            let bound = reconciliation(for: entry, descriptor: descriptor(for: entry), bindTo: entry.revision)
            let legacy = reconciliation(for: entry, descriptor: nil, bindTo: nil)

            XCTAssertTrue(
                BackupSyncRunner.receiptBelongs(bound, to: entry, resolvedRevision: entry.revision), "\(kind)")
            XCTAssertTrue(
                BackupSyncRunner.receiptBelongs(legacy, to: entry, resolvedRevision: entry.revision), "\(kind)")
            XCTAssertFalse(
                BackupSyncRunner.receiptBelongs(bound, to: entry, resolvedRevision: revision(20)),
                "a changed source must not settle with the receipt of its earlier revision (\(kind))")
            XCTAssertFalse(
                BackupSyncRunner.receiptBelongs(legacy, to: entry, resolvedRevision: revision(20)),
                "an older receipt without a binding must not settle a changed source either (\(kind))")
            XCTAssertFalse(
                BackupSyncRunner.receiptBelongs(
                    reconciliation(for: entry, descriptor: descriptor(for: entry), bindTo: revision(9)), to: entry,
                    resolvedRevision: entry.revision),
                "a receipt bound to another row settles nothing (\(kind))")
            XCTAssertFalse(
                BackupSyncRunner.receiptBelongs(
                    reconciliation(
                        for: entry, descriptor: descriptor(for: entry, filename: "other.jpg"), bindTo: entry.revision),
                    to: entry,
                    resolvedRevision: entry.revision),
                "a saved descriptor that does not match its row settles nothing (\(kind))")
        }
    }

    // MARK: - Route: the manifest write failed after the remote commit

    func testAChangedPhotoAfterAFailedManifestWriteUploadsItsOwnBytes() async throws {
        let entry = seedEntry("changed-after-commit.jpg")
        let pipeline = makePipeline()
        _ = await makeRunner(identityResolver: RecordFailingIdentityResolver(inner: pipeline, failures: 2))
            .runUntilDrained(mode: .eligibleOnly)
        let parked = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        let receipt = try XCTUnwrap(parked.remoteCommitReconciliation)
        XCTAssertEqual(parked.state, .needsRemoteReconciliation)
        XCTAssertEqual(uploader.requests.count, 1)

        // The photo changes before the receipt is reconciled.
        let changed = resolver.defaultModified.addingTimeInterval(120)
        resolver.setModified(changed, for: entry.source.identifier)
        hasher.contentSeeds[URL(fileURLWithPath: entry.source.identifier).path] = "changed content"
        clock.advance(by: 2)
        _ = await makeRunner(identityResolver: pipeline).runUntilDrained(mode: .eligibleOnly)

        XCTAssertEqual(uploader.requests.count, 2, "the changed revision uploads its own bytes")
        let record = try XCTUnwrap(identityStore.record(for: entry.source))
        XCTAssertEqual(record.modificationDate, changed)
        XCTAssertNotEqual(record.sha1Hex, receipt.identity.sha1Hex, "the record must hold the hash of the new bytes")
        XCTAssertNotEqual(record.remoteLinkID, receipt.receipt.remoteLinkID)
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    /// The scan queued the new revision, and the pass backs it up before it reaches the receipt of the old one. The old
    /// receipt must not replace the newer record of the source.
    func testAnEarlierReceiptNeverReplacesTheNewerBackupOfTheSource() async throws {
        let entry = seedEntry("backed-up-first.jpg")
        let pipeline = makePipeline()
        _ = await makeRunner(identityResolver: RecordFailingIdentityResolver(inner: pipeline, failures: 2))
            .runUntilDrained(mode: .eligibleOnly)
        let receipt = try XCTUnwrap(
            queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)

        let changed = resolver.defaultModified.addingTimeInterval(120)
        resolver.setModified(changed, for: entry.source.identifier)
        hasher.contentSeeds[URL(fileURLWithPath: entry.source.identifier).path] = "newer content"
        let newer = UploadBackupSyncQueueEntry(
            source: entry.source, revision: UploadBackupRevision(date: changed),
            originalFilename: entry.originalFilename, byteCount: entry.byteCount, updatedAt: clock.now)
        XCTAssertTrue(queueStore.upsert(newer))
        clock.advance(by: 2)
        // One item at a time: the newer revision runs first, the receipt of the old one after it.
        let recorder = RecordingIdentityResolver(inner: pipeline)
        _ = await makeRunner(identityResolver: recorder, concurrency: 1).runUntilDrained(mode: .eligibleOnly)

        XCTAssertFalse(recorder.linkIDs.isEmpty)
        XCTAssertFalse(
            recorder.linkIDs.contains(receipt.receipt.remoteLinkID),
            "the receipt of the old revision must not be recorded after the newer backup, not even for a moment")
        XCTAssertEqual(uploader.requests.count, 2, "only the newer revision uploads again")
        let record = try XCTUnwrap(identityStore.record(for: entry.source))
        XCTAssertEqual(record.modificationDate, changed, "the newer backup keeps its record")
        XCTAssertNotEqual(record.sha1Hex, receipt.identity.sha1Hex)
        XCTAssertNotEqual(record.remoteLinkID, receipt.receipt.remoteLinkID)
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    // MARK: - Route: the committed resource was not available for reconciliation

    func testAReceiptOfAMissingResourceDoesNotSettleTheResourceOfAChangedPhoto() async throws {
        let entry = seedEntry("live.jpg")
        let video = UploadSourceIdentity(
            kind: entry.source.kind, identifier: entry.source.identifier, resource: .livePairedVideo)
        let savedVideo = UploadResourceDescriptor(
            source: video, fileURL: URL(fileURLWithPath: "\(entry.source.identifier)#live.mov"),
            filename: "live.mov", fileSize: 2, modificationDate: resolver.defaultModified)
        let receipt = UploadRemoteCommitReconciliation(
            source: video,
            identity: UploadIdentity(
                correctedName: ProtonPhotoNameCorrection.correctedName(for: "live.mov"), nameHash: "video-name",
                sha1Hex: String(repeating: "ab", count: 20), sha1Digest: Data(repeating: 0xAB, count: 20),
                contentHash: "video-content"),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "earlier-video"),
            descriptor: UploadResourceDescriptorSnapshot(savedVideo),
            queueBinding: UploadRemoteCommitQueueBinding(source: entry.source, revision: entry.revision))
        XCTAssertTrue(
            queueStore.markNeedsRemoteReconciliation(
                source: entry.source, revision: entry.revision, reconciliation: receipt, lastError: "waiting",
                updatedAt: clock.now.addingTimeInterval(-60)))
        let pipeline = makePipeline()

        // The library does not list the video now: the row stays parked with its receipt.
        _ = await makeRunner(identityResolver: pipeline).runUntilDrained(mode: .eligibleOnly)
        let parked = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(parked.state, .needsRemoteReconciliation)
        XCTAssertEqual(parked.remoteCommitReconciliation, receipt)

        // The photo changes and lists its video again, with new bytes.
        resolver.setModified(resolver.defaultModified.addingTimeInterval(120), for: entry.source.identifier)
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        hasher.contentSeeds["\(entry.source.identifier)#live.mov"] = "changed video"
        clock.advance(by: 3600)
        _ = await makeRunner(identityResolver: pipeline).runUntilDrained(mode: .eligibleOnly)

        XCTAssertTrue(
            uploader.requests.contains { $0.name == "live.mov" }, "the changed video uploads its own bytes")
        let record = try XCTUnwrap(identityStore.record(for: video))
        XCTAssertNotEqual(record.remoteLinkID, "earlier-video", "the earlier receipt must not settle the new video")
        XCTAssertNotEqual(record.sha1Hex, receipt.identity.sha1Hex)
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    // MARK: - Fixtures

    private func revision(_ seconds: TimeInterval) -> UploadBackupRevision {
        UploadBackupRevision(date: Date(timeIntervalSince1970: seconds))
    }

    private func descriptor(
        for entry: UploadBackupSyncQueueEntry, filename: String? = nil
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: entry.source, fileURL: URL(fileURLWithPath: entry.source.identifier),
            filename: filename ?? entry.originalFilename, fileSize: entry.byteCount ?? 1, modificationDate: clock.now)
    }

    private func reconciliation(
        for entry: UploadBackupSyncQueueEntry, descriptor: UploadResourceDescriptor?,
        bindTo revision: UploadBackupRevision?
    ) -> UploadRemoteCommitReconciliation {
        UploadRemoteCommitReconciliation(
            source: entry.source,
            identity: UploadIdentity(
                correctedName: ProtonPhotoNameCorrection.correctedName(for: entry.originalFilename),
                nameHash: "name", sha1Hex: String(repeating: "cd", count: 20),
                sha1Digest: Data(repeating: 0xCD, count: 20), contentHash: "content"),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "link"),
            descriptor: descriptor.map(UploadResourceDescriptorSnapshot.init),
            queueBinding: revision.map { UploadRemoteCommitQueueBinding(source: entry.source, revision: $0) })
    }

    private func seedEntry(_ id: String) -> UploadBackupSyncQueueEntry {
        let entry = UploadBackupSyncQueueEntry(
            source: .file(URL(fileURLWithPath: "/backup/\(id)")),
            revision: UploadBackupRevision(date: resolver.defaultModified), originalFilename: id, byteCount: 4,
            updatedAt: clock.now.addingTimeInterval(-60))
        XCTAssertTrue(queueStore.upsert(entry))
        return entry
    }

    private func makePipeline() -> UploadDedupePipeline {
        UploadDedupePipeline(
            store: identityStore, hasher: hasher, checker: checker, resourceCoordinator: .shared,
            now: { [clock] in clock!.now })
    }

    private func makeRunner(identityResolver: any UploadIdentityResolving, concurrency: Int = 2) -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queueStore, preflight: preflight, resolver: resolver, identityResolver: identityResolver,
            uploader: uploader, tagAdder: nil, editReplacement: nil, resourceCoordinator: .shared,
            configuration: BackupSyncRunner.Configuration(
                uploadStallTimeout: 180, uploadStallPollInterval: 5,
                retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 4),
                throttle: BackupThrottlePolicy(baseConcurrency: concurrency)),
            throttleInputs: { .unconstrained }, runtimeChanges: nil, clock: clock, events: nil,
            now: { [clock] in clock!.now })
    }

    /// Forwards to the pipeline and keeps every recorded upload.
    private final class RecordingIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
        private let inner: UploadDedupePipeline
        private let lock = NSLock()
        private var recorded: [String] = []
        /// The Proton link of every recorded upload, in order.
        var linkIDs: [String] { lock.withLock { recorded } }

        init(inner: UploadDedupePipeline) { self.inner = inner }

        func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
            try await inner.resolve(descriptor)
        }

        func prepareRemoteIndex(
            progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
        ) async throws {
            try await inner.prepareRemoteIndex(progress: progress)
        }

        func prime(_ descriptors: [UploadResourceDescriptor]) async {
            await inner.prime(descriptors)
        }

        func recordUploaded(
            _ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String,
            remoteLinkID: String
        ) async throws {
            lock.withLock { recorded.append(remoteLinkID) }
            try await inner.recordUploaded(
                descriptor, identity: identity, remoteVolumeID: remoteVolumeID, remoteLinkID: remoteLinkID)
        }

        func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async {
            await inner.remoteCommitNeedsReconciliation(descriptor)
        }

        func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {
            await inner.uploadDidFail(descriptor)
        }
    }

    private final class MemoryStateStore: UploadBackupStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [UploadSourceIdentity: [UploadBackupRevision: UploadBackupAssetRecord]] = [:]

        func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
            lock.withLock { rows[source]?[revision] }
        }

        func hasAnyRecord(for source: UploadSourceIdentity) -> Bool {
            lock.withLock { !(rows[source]?.isEmpty ?? true) }
        }

        func upsert(_ record: UploadBackupAssetRecord) -> Bool {
            lock.withLock { rows[record.source, default: [:]][record.revision] = record }
            return true
        }

        func removeRecords(for source: UploadSourceIdentity, keeping revisions: Set<UploadBackupRevision>) -> Bool {
            lock.withLock { rows[source] = rows[source]?.filter { revisions.contains($0.key) } }
            return true
        }

        func count() -> Int {
            lock.withLock { rows.values.reduce(0) { $0 + $1.count } }
        }
    }
}
