import AlbumSyncCore
import Foundation
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

private final class RecoveryTestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !signaled else { return [] }
            signaled = true
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            return pending
        }
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if lock.withLock({ signaled }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if signaled { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    var isSignaled: Bool { lock.withLock { signaled } }
}

private final class RecoveryControlledBarrier: @unchecked Sendable {
    let firstEntered = RecoveryTestLatch()
    let secondEntered = RecoveryTestLatch()
    let firstExited = RecoveryTestLatch()
    private let lock = NSLock()
    private var enteredCount = 0
    private var exitedCount = 0
    private var releasePermits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        let entered = lock.withLock {
            enteredCount += 1
            return enteredCount
        }
        if entered == 1 { firstEntered.signal() }
        if entered == 2 { secondEntered.signal() }

        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if releasePermits > 0 {
                    releasePermits -= 1
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }

        let exited = lock.withLock {
            exitedCount += 1
            return exitedCount
        }
        if exited == 1 { firstExited.signal() }
    }

    func releaseOne() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !waiters.isEmpty else {
                releasePermits += 1
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume()
    }
}

private final class RecoveryIdentityRecorder: UploadIdentityResolving, @unchecked Sendable {
    struct Record: Equatable {
        let descriptor: UploadResourceDescriptorSnapshot
        let identity: UploadIdentity
        let volumeID: String
        let linkID: String
    }

    private let lock = NSLock()
    private var values: [Record] = []
    private var remainingFailures: Int
    private let preflight: UploadPreflightResult?

    init(failures: Int = 0, preflight: UploadPreflightResult? = nil) {
        remainingFailures = failures
        self.preflight = preflight
    }

    var records: [Record] { lock.withLock { values } }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        if let preflight { return preflight }
        throw UploadError.backend("normal dedupe resolution must not run during receipt settlement")
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        let shouldFail = lock.withLock {
            if remainingFailures > 0 {
                remainingFailures -= 1
                return true
            }
            values.append(
                Record(
                    descriptor: UploadResourceDescriptorSnapshot(descriptor),
                    identity: identity,
                    volumeID: remoteVolumeID,
                    linkID: remoteLinkID
                ))
            return false
        }
        if shouldFail { throw UploadError.backend("injected manifest failure") }
    }
}

private final class BlockingRecoveryIdentityRecorder: UploadIdentityResolving, @unchecked Sendable {
    let entered = RecoveryTestLatch()
    let cancellationObserved = RecoveryTestLatch()
    let release = RecoveryTestLatch()
    let completed = RecoveryTestLatch()
    private let lock = NSLock()
    private var writes = 0

    var writeCount: Int { lock.withLock { writes } }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        throw UploadError.backend("normal dedupe resolution must not run during receipt settlement")
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        entered.signal()
        await withTaskCancellationHandler {
            await release.wait()
        } onCancel: {
            cancellationObserved.signal()
        }
        lock.withLock { writes += 1 }
        completed.signal()
    }
}

private final class RecoveryResourceResolver: BackupResourceResolving, @unchecked Sendable {
    enum Result {
        case value(BackupResolvedResource?)
        case failure(any Error)
    }

    private let lock = NSLock()
    private let result: Result
    private var calls = 0

    init(_ result: Result) {
        self.result = result
    }

    var callCount: Int { lock.withLock { calls } }

    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        lock.withLock { calls += 1 }
        switch result {
        case .value(let value): return value
        case .failure(let error): throw error
        }
    }
}

final class UploadRemoteCommitRecoveryTests: XCTestCase {
    private var tempDirectory: URL!
    private let modified = Date(timeIntervalSince1970: 1_725_000_000)
    private let digest = Data(repeating: 0xA4, count: 20)

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-remote-commit-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testPersistedDescriptorRecoversCheckingPrimaryAfterReopenWithoutLocalRead() async throws {
        let source = source("primary")
        let descriptor = descriptor(source: source, filename: "primary.heic", fileExists: false)
        let reconciliation = reconciliation(descriptor: descriptor)
        let entry = seedEntry(reconciliation: reconciliation, state: .checking, byteCount: nil)
        let url = queueURL()
        try persist(entry, at: url)

        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let resolver = RecoveryResourceResolver(.failure(UploadError.backend("must not resolve")))
        let identityRecorder = RecoveryIdentityRecorder()
        let settled = try await UploadRemoteCommitRecovery(
            queue: reopened,
            resolver: resolver,
            identityResolver: identityRecorder
        ).settleAll()

        XCTAssertEqual(settled, 1)
        XCTAssertEqual(resolver.callCount, 0)
        XCTAssertNil(reopened.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(identityRecorder.records.first?.descriptor, UploadResourceDescriptorSnapshot(descriptor))
        XCTAssertEqual(identityRecorder.records.first?.linkID, "remote-primary")
    }

    func testDescriptorReceiptRejectsMissingOrWrongQueueBindingAndPrimaryEvidence() async throws {
        let queueSource = source("bound-primary")
        let queueRevision = revision()
        let validDescriptor = descriptor(source: queueSource, filename: "bound-primary.heic", fileExists: false)
        let receipt = UploadRemoteCommitReceipt(remoteVolumeID: "remote-volume", remoteLinkID: "remote-primary")
        let validIdentity = identity(filename: validDescriptor.filename)
        let wrongNameDescriptor = descriptor(source: queueSource, filename: "other.heic", fileExists: false)
        let wrongSizeDescriptor = descriptor(
            source: queueSource,
            filename: validDescriptor.filename,
            fileExists: false,
            fileSize: 8_192
        )
        let cases: [(String, UploadRemoteCommitReconciliation)] = [
            (
                "missing-binding",
                UploadRemoteCommitReconciliation(
                    source: queueSource,
                    identity: validIdentity,
                    receipt: receipt,
                    descriptor: UploadResourceDescriptorSnapshot(validDescriptor)
                )
            ),
            (
                "wrong-source",
                UploadRemoteCommitReconciliation(
                    source: queueSource,
                    identity: validIdentity,
                    receipt: receipt,
                    descriptor: UploadResourceDescriptorSnapshot(validDescriptor),
                    queueBinding: UploadRemoteCommitQueueBinding(
                        source: source("other-source"),
                        revision: queueRevision
                    )
                )
            ),
            (
                "wrong-revision",
                UploadRemoteCommitReconciliation(
                    source: queueSource,
                    identity: validIdentity,
                    receipt: receipt,
                    descriptor: UploadResourceDescriptorSnapshot(validDescriptor),
                    queueBinding: UploadRemoteCommitQueueBinding(
                        source: queueSource,
                        revision: UploadBackupRevision(rawValue: queueRevision.rawValue + 1)
                    )
                )
            ),
            (
                "wrong-resource",
                UploadRemoteCommitReconciliation(
                    source: queueSource,
                    identity: validIdentity,
                    receipt: receipt,
                    descriptor: UploadResourceDescriptorSnapshot(validDescriptor),
                    queueBinding: UploadRemoteCommitQueueBinding(
                        source: source("bound-primary", resource: .livePairedVideo),
                        revision: queueRevision
                    )
                )
            ),
            (
                "wrong-primary-name",
                UploadRemoteCommitReconciliation(
                    source: queueSource,
                    identity: identity(filename: wrongNameDescriptor.filename),
                    receipt: receipt,
                    descriptor: UploadResourceDescriptorSnapshot(wrongNameDescriptor),
                    queueBinding: UploadRemoteCommitQueueBinding(source: queueSource, revision: queueRevision)
                )
            ),
            (
                "wrong-known-size",
                UploadRemoteCommitReconciliation(
                    source: queueSource,
                    identity: validIdentity,
                    receipt: receipt,
                    descriptor: UploadResourceDescriptorSnapshot(wrongSizeDescriptor),
                    queueBinding: UploadRemoteCommitQueueBinding(source: queueSource, revision: queueRevision)
                )
            ),
        ]

        for (name, reconciliation) in cases {
            let directory = tempDirectory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite"))
            )
            let entry = seedEntry(source: queueSource, reconciliation: reconciliation)
            XCTAssertTrue(store.upsert(entry))
            let recorder = RecoveryIdentityRecorder()

            do {
                _ = try await UploadRemoteCommitRecovery(
                    queue: store,
                    resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
                    identityResolver: recorder
                ).settleAll()
                XCTFail("\(name) must fail closed")
            } catch let error as UploadRemoteCommitRecoveryError {
                XCTAssertTrue(
                    error == .invalidReceipt(entry.source, entry.revision)
                        || error == .descriptorMismatch(entry.source, entry.revision)
                )
            }
            XCTAssertTrue(recorder.records.isEmpty)
            XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        }
    }

    func testDescriptorReceiptRejectsWhitespaceIdentityHashesButAcceptsOpaqueValues() async throws {
        for (name, nameHash, contentHash) in [
            ("empty-name", "", "opaque-content"),
            ("whitespace-name", " \n\t", "opaque-content"),
            ("empty-content", "opaque-name", ""),
            ("whitespace-content", "opaque-name", " \n\t"),
        ] {
            let queueSource = source(name)
            let descriptor = descriptor(source: queueSource, filename: "\(name).heic", fileExists: false)
            let reconciliation = reconciliation(
                descriptor: descriptor,
                identity: identity(
                    filename: descriptor.filename,
                    nameHash: nameHash,
                    contentHash: contentHash
                )
            )
            let directory = tempDirectory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite"))
            )
            let entry = seedEntry(reconciliation: reconciliation)
            XCTAssertTrue(store.upsert(entry))

            do {
                _ = try await UploadRemoteCommitRecovery(
                    queue: store,
                    resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
                    identityResolver: RecoveryIdentityRecorder()
                ).settleAll()
                XCTFail("\(name) must fail closed")
            } catch let error as UploadRemoteCommitRecoveryError {
                XCTAssertEqual(error, .invalidReceipt(entry.source, entry.revision))
            }
            XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        }

        let opaqueSource = source("opaque-positive")
        let opaqueDescriptor = descriptor(
            source: opaqueSource,
            filename: "opaque-positive.heic",
            fileExists: false
        )
        let opaqueEntry = seedEntry(
            reconciliation: reconciliation(
                descriptor: opaqueDescriptor,
                identity: identity(
                    filename: opaqueDescriptor.filename,
                    nameHash: "shared-protocol-name-value",
                    contentHash: "shared-protocol-content-value"
                )
            )
        )
        let opaqueDirectory = tempDirectory.appendingPathComponent("opaque-positive", isDirectory: true)
        try FileManager.default.createDirectory(at: opaqueDirectory, withIntermediateDirectories: true)
        let opaqueStore = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: opaqueDirectory.appendingPathComponent("queue.sqlite"))
        )
        XCTAssertTrue(opaqueStore.upsert(opaqueEntry))
        let opaqueRecorder = RecoveryIdentityRecorder()
        let opaqueSettled = try await UploadRemoteCommitRecovery(
            queue: opaqueStore,
            resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            identityResolver: opaqueRecorder
        ).settleAll()
        XCTAssertEqual(opaqueSettled, 1)
        XCTAssertEqual(opaqueRecorder.records.count, 1)
    }

    func testInjectedManifestFailurePersistsReceiptAndReopenSettlesWithoutSecondUpload() async throws {
        let source = source("crash-window")
        let descriptor = descriptor(source: source, filename: "crash-window.heic", fileExists: false)
        let identity = identity(filename: descriptor.filename)
        let entry = UploadBackupSyncQueueEntry(
            source: source,
            revision: revision(),
            originalFilename: descriptor.filename,
            byteCount: descriptor.fileSize,
            updatedAt: modified
        )
        let queueURL = self.queueURL()
        let stateURL = tempDirectory.appendingPathComponent("state.sqlite")
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        let state = try XCTUnwrap(UploadBackupStateManifestStore(url: stateURL))
        XCTAssertTrue(queue.upsert(entry))
        // Both the initial settlement and the runner's immediate reconciliation must fail
        // before eligible-only mode leaves a durable receipt for the simulated restart.
        let identityResolver = RecoveryIdentityRecorder(
            failures: 2,
            preflight: UploadPreflightResult(identity: identity, decision: .upload)
        )
        let uploader = MockUploader()
        let resolved = resolvedResource(
            queueSource: source,
            revision: entry.revision,
            descriptor: descriptor
        )
        let resolver = RecoveryResourceResolver(.value(resolved))
        let runner = BackupSyncRunner(
            queue: queue,
            preflight: UploadBackupPreflightIndex(store: state),
            resolver: resolver,
            identityResolver: identityResolver,
            uploader: uploader
        )

        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        let pending = try XCTUnwrap(queue.entry(for: source, revision: entry.revision))
        XCTAssertEqual(pending.state, .needsRemoteReconciliation)
        XCTAssertEqual(pending.remoteCommitReconciliation?.descriptor, UploadResourceDescriptorSnapshot(descriptor))
        XCTAssertEqual(uploader.requests.count, 1)
        queue.close()
        state.close()

        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        let settledCount = try await UploadRemoteCommitRecovery(
            queue: reopened,
            resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            identityResolver: identityResolver
        ).settleAll()
        XCTAssertEqual(settledCount, 1)
        XCTAssertEqual(identityResolver.records.count, 1)
        XCTAssertEqual(uploader.requests.count, 1, "settlement replay must not call the uploader again")
        XCTAssertNil(reopened.entry(for: source, revision: entry.revision))
    }

    func testPersistedSecondaryRepairsExactRemoteLinkWithoutResolvingOrSchedulingSibling() async throws {
        let primary = source("live")
        let secondary = source("live", resource: .photoKit(role: "alternate", ordinal: 2))
        let descriptor = descriptor(source: secondary, filename: "live.mov", fileExists: false)
        XCTAssertNil(descriptor.mainResource)
        let reconciliation = reconciliation(
            descriptor: descriptor,
            queueSource: primary,
            linkID: "remote-secondary"
        )
        let entry = seedEntry(source: primary, reconciliation: reconciliation)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL()))
        XCTAssertTrue(store.upsert(entry))
        let resolver = RecoveryResourceResolver(.failure(UploadError.backend("must not resolve")))
        let recorder = RecoveryIdentityRecorder()

        let settledCount = try await UploadRemoteCommitRecovery(
            queue: store,
            resolver: resolver,
            identityResolver: recorder
        ).settleAll()
        XCTAssertEqual(settledCount, 1)

        XCTAssertEqual(resolver.callCount, 0)
        XCTAssertEqual(recorder.records.map(\.descriptor.source), [secondary])
        XCTAssertEqual(recorder.records.map(\.linkID), ["remote-secondary"])
    }

    func testLegacyReceiptUsesMatchedSecondaryAndDigestWithoutUploader() async throws {
        let primary = source("legacy-live")
        let secondary = source("legacy-live", resource: .livePairedVideo)
        let primaryDescriptor = descriptor(source: primary, filename: "legacy-live.heic", fileExists: false)
        let secondaryDescriptor = descriptor(source: secondary, filename: "legacy-live.mov", fileExists: false)
        let resolved = resolvedResource(
            queueSource: primary,
            revision: revision(),
            descriptor: primaryDescriptor,
            secondaries: [BackupSecondaryResource(descriptor: secondaryDescriptor, mediaType: "video/quicktime")]
        )
        let legacy = reconciliation(
            descriptor: nil,
            source: secondary,
            identity: identity(filename: secondaryDescriptor.filename)
        )
        let entry = seedEntry(source: primary, reconciliation: legacy)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL()))
        XCTAssertTrue(store.upsert(entry))
        let recorder = RecoveryIdentityRecorder()

        let settled = try await UploadRemoteCommitRecovery(
            queue: store,
            resolver: RecoveryResourceResolver(.value(resolved)),
            identityResolver: recorder
        ).settleAll()

        XCTAssertEqual(settled, 1)
        XCTAssertEqual(recorder.records.map(\.descriptor.source), [secondary])
        XCTAssertNil(store.entry(for: entry.source, revision: entry.revision))
    }

    func testLegacyMatchedSecondaryWithChangedDigestFailsClosed() async throws {
        let primary = source("legacy-digest")
        let secondary = source("legacy-digest", resource: .livePairedVideo)
        let primaryDescriptor = descriptor(source: primary, filename: "legacy-digest.heic", fileExists: false)
        let changedSecondary = UploadResourceDescriptor(
            source: secondary,
            fileURL: tempDirectory.appendingPathComponent("missing-legacy-digest.mov"),
            filename: "legacy-digest.mov",
            fileSize: 4_096,
            modificationDate: modified,
            precomputedSHA1Digest: Data(repeating: 0xB5, count: 20)
        )
        let resolved = resolvedResource(
            queueSource: primary,
            revision: revision(),
            descriptor: primaryDescriptor,
            secondaries: [BackupSecondaryResource(descriptor: changedSecondary, mediaType: "video/quicktime")]
        )
        let legacy = reconciliation(
            descriptor: nil,
            source: secondary,
            identity: identity(filename: changedSecondary.filename)
        )
        let entry = seedEntry(source: primary, reconciliation: legacy)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL()))
        XCTAssertTrue(store.upsert(entry))

        do {
            _ = try await UploadRemoteCommitRecovery(
                queue: store,
                resolver: RecoveryResourceResolver(.value(resolved)),
                identityResolver: RecoveryIdentityRecorder()
            ).settleAll()
            XCTFail("legacy recovery must require the exact digest")
        } catch let error as UploadRemoteCommitRecoveryError {
            XCTAssertEqual(error, .descriptorMismatch(entry.source, entry.revision))
        }
        XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    func testUnavailableManifestResolverPreservesReceiptAndSurfacesExistingBackendError() async throws {
        let queueSource = source("manifest-unavailable")
        let descriptor = descriptor(
            source: queueSource,
            filename: "manifest-unavailable.heic",
            fileExists: false
        )
        let entry = seedEntry(reconciliation: reconciliation(descriptor: descriptor))
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL()))
        XCTAssertTrue(store.upsert(entry))

        do {
            _ = try await UploadRemoteCommitRecovery(
                queue: store,
                resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
                identityResolver: DedupeUnavailableIdentityResolver(message: "manifest unavailable")
            ).settleAll()
            XCTFail("unavailable manifest settlement must fail closed")
        } catch let error as UploadError {
            guard case .backend(let message) = error else {
                return XCTFail("unexpected upload error: \(error)")
            }
            XCTAssertEqual(message, "manifest unavailable")
        }
        XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    func testLegacyReceiptUsesOnlyMatchingCurrentDescriptorAndJoinsCleanup() async throws {
        let source = source("legacy")
        let descriptor = descriptor(source: source, filename: "legacy.heic", fileExists: false)
        let cleanup = RecoveryTestLatch()
        let resolved = resolvedResource(
            queueSource: source,
            revision: revision(),
            descriptor: descriptor,
            cleanup: { cleanup.signal() }
        )
        let legacy = reconciliation(descriptor: nil, source: source)
        let entry = seedEntry(source: source, reconciliation: legacy)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL()))
        XCTAssertTrue(store.upsert(entry))
        let recorder = RecoveryIdentityRecorder()

        let settledCount = try await UploadRemoteCommitRecovery(
            queue: store,
            resolver: RecoveryResourceResolver(.value(resolved)),
            identityResolver: recorder
        ).settleAll()
        XCTAssertEqual(settledCount, 1)

        XCTAssertTrue(cleanup.isSignaled)
        XCTAssertEqual(recorder.records.map(\.descriptor.source), [source])
        XCTAssertNil(store.entry(for: entry.source, revision: entry.revision))
    }

    func testLegacyMissingOrChangedDescriptorFailsClosedAndPreservesReceipt() async throws {
        for changed in [false, true] {
            let directory = tempDirectory.appendingPathComponent(changed ? "changed" : "missing", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = source(changed ? "changed" : "missing")
            let legacy = reconciliation(descriptor: nil, source: source)
            let entry = seedEntry(source: source, reconciliation: legacy)
            let url = directory.appendingPathComponent("queue.sqlite")
            let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            XCTAssertTrue(store.upsert(entry))
            let value =
                changed
                ? resolvedResource(
                    queueSource: source,
                    revision: UploadBackupRevision(rawValue: revision().rawValue + 1),
                    descriptor: descriptor(source: source, filename: "changed.heic", fileExists: false)
                )
                : nil

            do {
                _ = try await UploadRemoteCommitRecovery(
                    queue: store,
                    resolver: RecoveryResourceResolver(.value(value)),
                    identityResolver: RecoveryIdentityRecorder()
                ).settleAll()
                XCTFail("legacy receipt without matching evidence must fail")
            } catch {
                XCTAssertTrue(error is UploadRemoteCommitRecoveryError)
            }
            XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        }
    }

    func testManifestFailureAndCancellationPreserveDurableReceipt() async throws {
        let source = source("preserved")
        let descriptor = descriptor(source: source, filename: "preserved.heic", fileExists: false)
        let entry = seedEntry(source: source, reconciliation: reconciliation(descriptor: descriptor))
        let url = queueURL()
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertTrue(store.upsert(entry))

        do {
            _ = try await UploadRemoteCommitRecovery(
                queue: store,
                resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
                identityResolver: RecoveryIdentityRecorder(failures: 1)
            ).settleAll()
            XCTFail("injected manifest failure must surface")
        } catch {}
        XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)

        let blocker = BlockingRecoveryIdentityRecorder()
        let recovery = Task {
            try await UploadRemoteCommitRecovery(
                queue: store,
                resolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
                identityResolver: blocker
            ).settleAll()
        }
        await blocker.entered.wait()
        recovery.cancel()
        await blocker.cancellationObserved.wait()
        blocker.release.signal()
        do {
            _ = try await recovery.value
            XCTFail("cancelled settlement must fail")
        } catch is CancellationError {}

        XCTAssertEqual(blocker.writeCount, 1)
        XCTAssertNotNil(store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
        store.close()
        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertNotNil(reopened.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    func testMalformedJSONAndSQLReadFailureAreNotDecodedAsNoReceipt() throws {
        let source = source("malformed")
        let descriptor = descriptor(source: source, filename: "malformed.heic", fileExists: false)
        let entry = seedEntry(source: source, reconciliation: reconciliation(descriptor: descriptor))
        let malformedURL = tempDirectory.appendingPathComponent("malformed.sqlite")
        try persist(entry, at: malformedURL)
        try executeSQL(
            "UPDATE backup_sync_queue SET remote_commit_reconciliation=x'00ff' WHERE source_id='malformed';",
            at: malformedURL
        )
        let malformedStore = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: malformedURL))
        XCTAssertThrowsError(try malformedStore.entriesWithRemoteCommitReconciliation(limit: 32)) { error in
            XCTAssertEqual(
                error as? UploadRemoteCommitRecoveryError,
                .malformedReceipt(source, entry.revision)
            )
        }
        malformedStore.close()
        let ordinaryReader = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: malformedURL))
        XCTAssertTrue(ordinaryReader.nextRunnable(limit: 1).isEmpty)
        XCTAssertFalse(ordinaryReader.isOperational(), "malformed receipt must not become ordinary runnable work")
        ordinaryReader.close()
        XCTAssertEqual(try receiptCount(in: "backup_sync_queue", at: malformedURL), 1)

        let readFailureURL = tempDirectory.appendingPathComponent("read-failure.sqlite")
        try persist(entry, at: readFailureURL)
        let readFailureStore = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: readFailureURL))
        try executeSQL("ALTER TABLE backup_sync_queue RENAME TO preserved_queue;", at: readFailureURL)
        XCTAssertThrowsError(try readFailureStore.entriesWithRemoteCommitReconciliation(limit: 32)) { error in
            XCTAssertEqual(error as? UploadRemoteCommitRecoveryError, .storeUnavailable)
        }
        readFailureStore.close()
        XCTAssertEqual(try receiptCount(in: "preserved_queue", at: readFailureURL), 1)
    }

    func testAlbumExecutorRecoversBeforeResetKeepsCurrentRunCountsAndNeverCallsUploader() async throws {
        let source = source("executor")
        let descriptor = descriptor(source: source, filename: "executor.heic", fileExists: false)
        let entry = seedEntry(source: source, reconciliation: reconciliation(descriptor: descriptor))
        try persist(entry, at: albumQueueURL())
        let recorder = RecoveryIdentityRecorder()
        let uploader = MockUploader()
        let resolver = RecoveryResourceResolver(.failure(UploadError.backend("must not resolve old receipt")))
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: recorder,
            uploader: uploader,
            resourceResolver: resolver
        )

        let report = try await executor.ensureBackedUp(
            localIdentifiers: ["D4-nonexistent-\(UUID().uuidString)"],
            onProgress: { _ in }
        )

        XCTAssertEqual(report, AlbumSyncBackupReport())
        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(resolver.callCount, 0)
        XCTAssertTrue(uploader.requests.isEmpty, "settlement-only replay must have no uploader path")
        let currentRunQueue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: albumQueueURL()))
        XCTAssertEqual(currentRunQueue.count(), 0)
    }

    func testEmptyAlbumInvocationSettlesPreviouslySelectedReceiptBeforeReturning() async throws {
        let queueSource = source("previously-selected")
        let descriptor = descriptor(
            source: queueSource,
            filename: "previously-selected.heic",
            fileExists: false
        )
        let entry = seedEntry(reconciliation: reconciliation(descriptor: descriptor))
        try persist(entry, at: albumQueueURL())
        let recorder = RecoveryIdentityRecorder()
        let uploader = MockUploader()
        let resolver = RecoveryResourceResolver(.failure(UploadError.backend("must not scan or resolve")))
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: recorder,
            uploader: uploader,
            resourceResolver: resolver
        )

        let report = try await executor.ensureBackedUp(localIdentifiers: [], onProgress: { _ in })

        XCTAssertEqual(report, AlbumSyncBackupReport())
        XCTAssertEqual(recorder.records.map(\.descriptor.source), [queueSource])
        XCTAssertEqual(resolver.callCount, 0)
        XCTAssertTrue(uploader.requests.isEmpty)
        let resetQueue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: albumQueueURL()))
        XCTAssertEqual(resetQueue.count(), 0)
    }

    func testAlbumExecutorMalformedReceiptFailsBeforeScratchReset() async throws {
        let source = source("executor-malformed")
        let descriptor = descriptor(source: source, filename: "executor-malformed.heic", fileExists: false)
        let entry = seedEntry(source: source, reconciliation: reconciliation(descriptor: descriptor))
        let url = albumQueueURL()
        try persist(entry, at: url)
        try executeSQL(
            "UPDATE backup_sync_queue SET remote_commit_reconciliation=x'00ff' "
                + "WHERE source_id='executor-malformed';",
            at: url
        )
        let uploader = MockUploader()
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: RecoveryIdentityRecorder(),
            uploader: uploader,
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve")))
        )

        do {
            _ = try await executor.ensureBackedUp(
                localIdentifiers: ["D4-never-scanned"],
                onProgress: { _ in }
            )
            XCTFail("malformed durable receipt must abort the album run")
        } catch let error as UploadRemoteCommitRecoveryError {
            XCTAssertEqual(error, .malformedReceipt(source, entry.revision))
        }

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(try receiptCount(in: "backup_sync_queue", at: url), 1)
    }

    func testAlbumExecutorStopCancelsAndJoinsRecoveryBeforeClosingStores() async throws {
        let source = source("stop")
        let descriptor = descriptor(source: source, filename: "stop.heic", fileExists: false)
        let entry = seedEntry(source: source, reconciliation: reconciliation(descriptor: descriptor))
        try persist(entry, at: albumQueueURL())
        let blocker = BlockingRecoveryIdentityRecorder()
        let uploader = MockUploader()
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: blocker,
            uploader: uploader,
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve")))
        )
        let ensure = Task {
            try await executor.ensureBackedUp(
                localIdentifiers: ["D4-never-scanned"],
                onProgress: { _ in }
            )
        }
        await blocker.entered.wait()
        let stopReturned = RecoveryTestLatch()
        let stop = Task {
            await executor.stop()
            stopReturned.signal()
        }
        await blocker.cancellationObserved.wait()
        XCTAssertFalse(stopReturned.isSignaled, "stop must join cancellation-ignoring recovery")
        blocker.release.signal()
        await stop.value

        XCTAssertTrue(blocker.completed.isSignaled)
        XCTAssertTrue(stopReturned.isSignaled)
        XCTAssertEqual(blocker.writeCount, 1)
        XCTAssertTrue(uploader.requests.isEmpty)
        do {
            _ = try await ensure.value
            XCTFail("stopped executor must surface cancellation")
        } catch is CancellationError {}

        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: albumQueueURL()))
        XCTAssertNotNil(reopened.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    func testStopFenceRejectsAdmissionAfterOperationJoinsUntilStopReturns() async throws {
        let queueSource = source("stop-fence")
        let descriptor = descriptor(source: queueSource, filename: "stop-fence.heic", fileExists: false)
        let entry = seedEntry(reconciliation: reconciliation(descriptor: descriptor))
        try persist(entry, at: albumQueueURL())
        let recorder = BlockingRecoveryIdentityRecorder()
        let fenceRelease = RecoveryControlledBarrier()
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: recorder,
            uploader: MockUploader(),
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            stopFenceBarrier: { await fenceRelease.wait() }
        )
        let ensure = Task {
            try await executor.ensureBackedUp(localIdentifiers: ["not-scanned"], onProgress: { _ in })
        }
        await recorder.entered.wait()
        let stop = Task { await executor.stop() }
        await recorder.cancellationObserved.wait()
        recorder.release.signal()
        await fenceRelease.firstEntered.wait()

        do {
            _ = try await executor.ensureBackedUp(localIdentifiers: [], onProgress: { _ in })
            XCTFail("stop fence must reject admission after the captured operation has joined")
        } catch let error as AlbumSyncError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        fenceRelease.releaseOne()
        await stop.value
        do {
            _ = try await ensure.value
            XCTFail("stopped operation must surface cancellation")
        } catch is CancellationError {}

        let report = try await executor.ensureBackedUp(localIdentifiers: [], onProgress: { _ in })
        XCTAssertEqual(report, AlbumSyncBackupReport())
    }

    func testOverlappingStopsRetainIndependentAdmissionFences() async throws {
        let queueSource = source("overlapping-stops")
        let descriptor = descriptor(
            source: queueSource,
            filename: "overlapping-stops.heic",
            fileExists: false
        )
        let entry = seedEntry(reconciliation: reconciliation(descriptor: descriptor))
        try persist(entry, at: albumQueueURL())
        let recorder = BlockingRecoveryIdentityRecorder()
        let acquired = RecoveryControlledBarrier()
        let releasing = RecoveryControlledBarrier()
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: recorder,
            uploader: MockUploader(),
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve"))),
            stopFenceAcquired: { await acquired.wait() },
            stopFenceBarrier: { await releasing.wait() }
        )
        let ensure = Task {
            try await executor.ensureBackedUp(localIdentifiers: ["not-scanned"], onProgress: { _ in })
        }
        await recorder.entered.wait()

        let firstStop = Task { await executor.stop() }
        await acquired.firstEntered.wait()
        let secondStop = Task { await executor.stop() }
        await acquired.secondEntered.wait()

        acquired.releaseOne()
        await recorder.cancellationObserved.wait()
        recorder.release.signal()
        await releasing.firstEntered.wait()
        acquired.releaseOne()
        await releasing.secondEntered.wait()

        do {
            _ = try await executor.ensureBackedUp(localIdentifiers: [], onProgress: { _ in })
            XCTFail("two stop owners must fence admission")
        } catch let error as AlbumSyncError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        releasing.releaseOne()
        await firstStop.value
        do {
            _ = try await executor.ensureBackedUp(localIdentifiers: [], onProgress: { _ in })
            XCTFail("the remaining stop owner must retain its fence")
        } catch let error as AlbumSyncError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        releasing.releaseOne()
        await secondStop.value
        do {
            _ = try await ensure.value
            XCTFail("stopped operation must surface cancellation")
        } catch is CancellationError {}

        let report = try await executor.ensureBackedUp(localIdentifiers: [], onProgress: { _ in })
        XCTAssertEqual(report, AlbumSyncBackupReport())
    }

    func testPreCancelledAlbumExecutorDoesNotOpenStoresOrStartUploadWork() async throws {
        let uploader = MockUploader()
        let executor = PhotoAlbumBackupExecutor(
            accountDataDirectory: tempDirectory,
            databasePolicy: .conservative,
            identityResolver: RecoveryIdentityRecorder(),
            uploader: uploader,
            resourceResolver: RecoveryResourceResolver(.failure(UploadError.backend("must not resolve")))
        )

        let attempt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.ensureBackedUp(
                localIdentifiers: ["D4-pre-cancelled"],
                onProgress: { _ in }
            )
        }
        do {
            _ = try await attempt.value
            XCTFail("pre-cancelled album run must fail before admission")
        } catch is CancellationError {}

        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: albumQueueURL().path))
    }

    private func source(
        _ identifier: String,
        resource: UploadSourceIdentity.Resource = .primary
    ) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier, resource: resource)
    }

    private func revision() -> UploadBackupRevision {
        UploadBackupRevision(date: modified)
    }

    private func descriptor(
        source: UploadSourceIdentity,
        filename: String,
        fileExists: Bool,
        fileSize: Int64 = 4_096
    ) -> UploadResourceDescriptor {
        let url = tempDirectory.appendingPathComponent(fileExists ? filename : "missing-\(filename)")
        return UploadResourceDescriptor(
            source: source,
            fileURL: url,
            filename: filename,
            fileSize: fileSize,
            modificationDate: modified,
            precomputedSHA1Digest: digest
        )
    }

    private func identity(
        filename: String,
        nameHash: String? = nil,
        contentHash: String? = nil
    ) -> UploadIdentity {
        UploadIdentity(
            correctedName: ProtonPhotoNameCorrection.correctedName(for: filename),
            nameHash: nameHash ?? "name-hash-\(filename)",
            sha1Hex: UploadContentSHA1.hexString(digest: digest),
            sha1Digest: digest,
            contentHash: contentHash ?? "content-hash-\(filename)"
        )
    }

    private func reconciliation(
        descriptor: UploadResourceDescriptor?,
        source explicitSource: UploadSourceIdentity? = nil,
        queueSource explicitQueueSource: UploadSourceIdentity? = nil,
        queueRevision: UploadBackupRevision? = nil,
        identity explicitIdentity: UploadIdentity? = nil,
        linkID: String = "remote-primary"
    ) -> UploadRemoteCommitReconciliation {
        let source = explicitSource ?? descriptor!.source
        let filename = descriptor?.filename ?? "\(source.identifier).heic"
        let queueSource =
            explicitQueueSource
            ?? UploadSourceIdentity(kind: source.kind, identifier: source.identifier, resource: .primary)
        return UploadRemoteCommitReconciliation(
            source: source,
            identity: explicitIdentity ?? identity(filename: filename),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "remote-volume", remoteLinkID: linkID),
            descriptor: descriptor.map(UploadResourceDescriptorSnapshot.init),
            queueBinding: descriptor.map { _ in
                UploadRemoteCommitQueueBinding(
                    source: queueSource,
                    revision: queueRevision ?? revision()
                )
            }
        )
    }

    private func seedEntry(
        source explicitSource: UploadSourceIdentity? = nil,
        reconciliation: UploadRemoteCommitReconciliation,
        state: UploadBackupSyncQueueState = .needsRemoteReconciliation,
        byteCount: Int64? = 4_096
    ) -> UploadBackupSyncQueueEntry {
        let source = explicitSource ?? reconciliation.source
        return UploadBackupSyncQueueEntry(
            source: source,
            revision: revision(),
            originalFilename: "\(source.identifier).heic",
            byteCount: byteCount,
            state: state,
            remoteCommitReconciliation: reconciliation,
            updatedAt: modified
        )
    }

    private func resolvedResource(
        queueSource: UploadSourceIdentity,
        revision: UploadBackupRevision,
        descriptor: UploadResourceDescriptor,
        secondaries: [BackupSecondaryResource] = [],
        cleanup: (@Sendable () -> Void)? = nil
    ) -> BackupResolvedResource {
        BackupResolvedResource(
            candidate: UploadBackupAssetCandidate(
                snapshot: UploadBackupAssetSnapshot(
                    source: queueSource,
                    revision: revision,
                    editRevision: .unavailable,
                    resourceCount: 1 + secondaries.count
                ),
                originalFilename: descriptor.filename,
                byteCount: descriptor.fileSize
            ),
            descriptor: descriptor,
            mediaType: "image/heic",
            captureDate: modified,
            secondaries: secondaries,
            cleanup: cleanup
        )
    }

    private func queueURL() -> URL {
        tempDirectory.appendingPathComponent("queue.sqlite")
    }

    private func albumQueueURL() -> URL {
        tempDirectory.appendingPathComponent(PhotoAlbumBackupExecutor.queueDatabaseFileName)
    }

    private func persist(_ entry: UploadBackupSyncQueueEntry, at url: URL) throws {
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertTrue(store.upsert(entry))
        store.close()
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    private func receiptCount(in table: String, at url: URL) throws -> Int {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle,
                "SELECT COUNT(*) FROM \(table) WHERE remote_commit_reconciliation IS NOT NULL;",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }
}
