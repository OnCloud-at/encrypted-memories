import Foundation
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

final class PhotoKitStagingSinkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photokit-staging-sink-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(maximumBytes: Int64 = 1 << 20, freeBytes: Int64 = 1 << 40) -> BackupTempFileStore {
        BackupTempFileStore(
            directory: directory,
            maximumBytes: maximumBytes,
            minimumFreeBytes: 0,
            availableCapacity: { _ in freeBytes },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func digest(of chunks: [Data]) -> Data {
        let sha1 = UploadSHA1Accumulator()
        chunks.forEach { sha1.update($0) }
        return sha1.finalizeDigest()
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    func testAnOriginalFromICloudIsHashedAndStagedInOnePass() throws {
        let tempStore = store()
        let chunks = [Data("first ".utf8), Data("second".utf8)]
        let sink = PhotoKitStagingSink(tempStore: tempStore, filename: "IMG_1.HEIC")
        chunks.forEach(sink.receive)

        let result = sink.finish()

        let staged = try XCTUnwrap(result.stagedURL)
        XCTAssertFalse(staged.lastPathComponent.hasSuffix(".partial"))
        XCTAssertEqual(try Data(contentsOf: staged), Data("first second".utf8))
        XCTAssertEqual(result.byteCount, 12)
        XCTAssertEqual(result.sha1Digest, digest(of: chunks))
        tempStore.discard(staged)
        XCTAssertEqual(tempStore.usedBytes(), 0)
    }

    func testAFullBudgetDropsTheFileButStillHashesEveryByte() {
        let tempStore = store(maximumBytes: 8)
        let chunks = [Data("12345".utf8), Data("67890".utf8), Data("abc".utf8)]
        let sink = PhotoKitStagingSink(tempStore: tempStore, filename: "IMG_2.MOV")
        chunks.forEach(sink.receive)

        let result = sink.finish()

        XCTAssertNil(result.stagedURL, "the upload exports the original again instead")
        XCTAssertEqual(result.byteCount, 13)
        XCTAssertEqual(result.sha1Digest, digest(of: chunks))
        XCTAssertTrue(files().isEmpty, "the partial file must not stay behind")
    }

    func testLowDiskSpaceDropsTheFileButStillHashesEveryByte() {
        let tempStore = store(freeBytes: 4)
        let chunks = [Data("12345".utf8)]
        let sink = PhotoKitStagingSink(tempStore: tempStore, filename: "IMG_3.HEIC")
        chunks.forEach(sink.receive)

        let result = sink.finish()

        XCTAssertNil(result.stagedURL)
        XCTAssertEqual(result.sha1Digest, digest(of: chunks))
        XCTAssertTrue(files().isEmpty)
    }

    func testARefusedReservationOnlyHashes() throws {
        let tempStore = store(maximumBytes: 8)
        // A large export that owns the overflow slot refuses any staging beside it.
        let large = try tempStore.reserve(filename: "LARGE.MOV", expectedBytes: 64)
        let sink = PhotoKitStagingSink(tempStore: tempStore, filename: "IMG_4.HEIC")
        XCTAssertFalse(sink.isStaging)
        sink.receive(Data("abc".utf8))

        let result = sink.finish()

        XCTAssertNil(result.stagedURL)
        XCTAssertEqual(result.byteCount, 3)
        tempStore.discard(large)
    }

    func testAnAbandonedDownloadRemovesItsPartialFile() {
        let tempStore = store()
        let sink = PhotoKitStagingSink(tempStore: tempStore, filename: "IMG_5.HEIC")
        sink.receive(Data("partial".utf8))
        XCTAssertFalse(files().isEmpty)

        sink.abandon()

        XCTAssertTrue(files().isEmpty)
        XCTAssertEqual(tempStore.usedBytes(), 0)
    }
}
