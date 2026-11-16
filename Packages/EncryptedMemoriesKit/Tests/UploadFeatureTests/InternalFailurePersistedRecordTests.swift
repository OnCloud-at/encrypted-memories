import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// An internal failure shows the text of the old backend error and stores the same row (#1159).
final class InternalFailurePersistedRecordTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "internal-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEveryInternalFailureKeepsTheTextOfTheBackendErrorItReplaces() {
        let message = L10n.string("backup.error_local_state_unavailable")
        XCTAssertEqual(Set(UploadError.InternalFailure.allCases), [.localStateUnavailable])
        for failure in UploadError.InternalFailure.allCases {
            XCTAssertEqual(failure.message, message, "\(failure)")
            XCTAssertEqual(failure.failureCause, .localState, "\(failure)")
            XCTAssertEqual(UploadError.internalFailure(failure).errorDescription, message, "\(failure)")
            XCTAssertEqual(UploadError.internalFailure(failure).failureCause, .localState, "\(failure)")
        }
        XCTAssertEqual(
            UploadError.internalFailure(.localStateUnavailable).errorDescription,
            UploadError.backend(message).errorDescription)
    }

    /// Runs one photo through the runner whose upload fails with `error`, and returns the stored `lastError` and state.
    private func storedRow(
        after error: any Error
    ) async throws -> (lastError: String?, state: UploadBackupSyncQueueState?) {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent(UUID().uuidString + ".sqlite")))
        defer { queue.close() }
        let clock = BackupTestClock()
        let resolver = ScriptedBackupResolver(defaultModified: clock.now.addingTimeInterval(-3600))
        let preflight = UploadBackupPreflightIndex(store: MemoryBackupStateStore(), now: { clock.now })
        let pipeline = UploadDedupePipeline(
            store: FakeIdentityStore(), hasher: FakeHasher(), checker: FakeChecker(),
            resourceCoordinator: .shared, now: { clock.now })
        let entry = UploadBackupSyncQueueEntry(
            source: .file(URL(fileURLWithPath: "/backup/failing.jpg")),
            revision: UploadBackupRevision(date: resolver.defaultModified), originalFilename: "failing.jpg",
            byteCount: 4, state: .discovered, attempts: 0, updatedAt: clock.now.addingTimeInterval(-60))
        XCTAssertTrue(queue.upsert(entry))
        let runner = BackupSyncRunner(
            queue: queue, preflight: preflight, resolver: resolver, identityResolver: pipeline,
            uploader: ThrowingUploader(error: error), tagAdder: SpyTagAdder(),
            configuration: BackupSyncRunner.Configuration(
                retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 1, maxAttempts: 1),
                throttle: BackupThrottlePolicy(baseConcurrency: 1)),
            clock: clock, now: { clock.now })
        _ = await runner.runUntilDrained()
        let row = try queue.entry(for: entry.source, revision: entry.revision)
        return (row?.lastError, row?.state)
    }

    /// The record that the runner stores for an internal failure equals the record of the backend error with the same text.
    func testTheStoredRowOfAnInternalFailureEqualsTheRowOfTheBackendErrorItReplaces() async throws {
        let oldError = UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        let before = try await storedRow(after: oldError)
        let after = try await storedRow(after: UploadError.internalFailure(.localStateUnavailable))

        XCTAssertEqual(after.state, before.state, "the item parks the same way")
        // The encoder writes the keys of the record in no fixed order, so two equal records differ in their bytes.
        // The record that each row decodes to is the value that the app reads.
        let record = try XCTUnwrap(BackupIssueRecord.decode(after.lastError))
        XCTAssertEqual(record, BackupIssueRecord.decode(before.lastError), "the stored record is equal")
        XCTAssertEqual(record.kind, .remoteService, "the persisted kind of a backend failure")
        XCTAssertEqual(record.detail, L10n.string("backup.error_local_state_unavailable"))
    }
}

/// Fails every upload with one error. The other calls answer like the mock uploader.
private final class ThrowingUploader: PhotoUploading, @unchecked Sendable {
    private let inner = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
    private let error: any Error

    init(error: any Error) { self.error = error }

    var capabilities: UploadBackendCapabilities { inner.capabilities }

    func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
        try await inner.reserveNetwork(allowsExpensiveNetwork: allowsExpensiveNetwork)
    }

    func upload(
        _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        throw error
    }

    func cancel(token: UUID) async { await inner.cancel(token: token) }
    func pause(token: UUID) async throws { try await inner.pause(token: token) }
    func resume(token: UUID) async throws { try await inner.resume(token: token) }
}
