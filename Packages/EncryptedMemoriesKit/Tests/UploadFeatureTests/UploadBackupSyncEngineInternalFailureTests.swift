import Foundation
import XCTest

@testable import UploadCore

/// The engine reports an unavailable exclusion answer and a missing source recovery as fixed internal failures (#1159).
final class UploadBackupSyncEngineInternalFailureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "engine-internal-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAnUnknownExclusionAnswerStopsTheEnqueueWithTheFixedInternalFailure() async throws {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite")))
        defer { queue.close() }
        let engine = UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: MemoryBackupStateStore()), queue: queue,
            exclusions: UnknownExclusions())
        let snapshot = UploadBackupAssetSnapshot(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-1"),
            revision: UploadBackupRevision(date: Date(timeIntervalSinceReferenceDate: 10)), resourceCount: 1)
        let candidate = UploadBackupAssetCandidate(snapshot: snapshot, originalFilename: "IMG_1.JPG")

        do {
            _ = try await engine.enqueueBatch([candidate])
            XCTFail("an unknown exclusion answer must not enqueue the photo")
        } catch UploadError.internalFailure(let failure) {
            XCTAssertEqual(failure, .exclusionsUnavailable)
            XCTAssertEqual(failure.message, "Backup exclusions are unavailable")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(queue.count(), 0)
    }

    func testAnEnqueuerWithoutSourceRecoveryFailsWithTheFixedInternalFailure() async {
        let enqueuer = EnqueuerWithDefaults()
        do {
            try await enqueuer.enqueueMissingSources([])
            XCTFail("the default has no source recovery")
        } catch UploadError.internalFailure(let failure) {
            XCTAssertEqual(failure, .sourceRecoveryUnavailable)
            XCTAssertEqual(failure.message, "Backup source recovery is unavailable")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        do {
            _ = try await enqueuer.missingSourceDiscardGeneration()
            XCTFail("the default has no source recovery")
        } catch UploadError.internalFailure(let failure) {
            XCTAssertEqual(failure, .sourceRecoveryUnavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private struct UnknownExclusions: UploadBackupExclusionFiltering {
    func exclusions(kind: UploadSourceIdentity.Kind, among identifiers: [String]) -> [String: BackupSourceExclusion]? {
        nil
    }
}

/// Implements only the required members, so the protocol defaults answer for the rest.
private struct EnqueuerWithDefaults: UploadBackupCandidateEnqueueing {
    func enqueue(_ candidate: UploadBackupAssetCandidate) async throws -> UploadBackupSyncScanResult {
        UploadBackupSyncScanResult()
    }

    func synchronizeQueueToDisk() async -> Bool { true }
}
