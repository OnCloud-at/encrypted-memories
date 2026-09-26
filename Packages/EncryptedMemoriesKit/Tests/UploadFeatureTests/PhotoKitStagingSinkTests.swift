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

    func testAnOriginalLargerThanHalfTheBudgetIsOnlyHashed() throws {
        let fits = PhotoKitStagingSink(tempStore: store(maximumBytes: 100), filename: "IMG_6.MOV")
        [Data(count: 25), Data(count: 25)].forEach(fits.receive)
        let staged = try XCTUnwrap(fits.finish().stagedURL, "half of the budget may stage")
        XCTAssertEqual(try Data(contentsOf: staged).count, 50)
        try FileManager.default.removeItem(at: staged)

        let tooLarge = PhotoKitStagingSink(tempStore: store(maximumBytes: 100), filename: "IMG_7.MOV")
        let chunks = [Data(count: 30), Data(count: 30)]
        chunks.forEach(tooLarge.receive)
        let result = tooLarge.finish()

        XCTAssertNil(result.stagedURL, "one large video must not fill the budget of every other photo")
        XCTAssertEqual(result.byteCount, 60)
        XCTAssertEqual(result.sha1Digest, digest(of: chunks))
        XCTAssertTrue(files().isEmpty)
    }

    func testConcurrentStagingSharesHalfTheBudgetAndLeavesTheRestForUploads() throws {
        let tempStore = store(maximumBytes: 100)
        let first = PhotoKitStagingSink(tempStore: tempStore, filename: "IMG_8.MOV")
        let second = PhotoKitStagingSink(tempStore: tempStore, filename: "IMG_9.MOV")
        first.receive(Data(count: 30))
        second.receive(Data(count: 30))

        XCTAssertTrue(first.isStaging)
        XCTAssertFalse(second.isStaging, "two staged files together may not exceed half of the budget")

        // A photo already selected for upload still gets the other half.
        let export = try tempStore.reserve(filename: "IMG_10.HEIC", expectedBytes: 60)
        try tempStore.recordWrite(to: export, byteCount: 60)
        tempStore.discard(export)
        _ = first.finish()
        _ = second.finish()
    }

    func testALargeOriginalOfKnownSizeStagesInTheLargeFileSlotAndDownloadsOnce() throws {
        let tempStore = store(maximumBytes: 100)
        let chunks = [Data(count: 120), Data(count: 120)]
        let sink = PhotoKitStagingSink(tempStore: tempStore, filename: "PRORES.MOV", expectedBytes: 240)
        XCTAssertTrue(sink.isStaging, "a known size above half the budget still stages, exclusively")
        chunks.forEach(sink.receive)

        let result = sink.finish()

        let staged = try XCTUnwrap(result.stagedURL)
        XCTAssertEqual(try Data(contentsOf: staged).count, 240)
        XCTAssertEqual(result.sha1Digest, digest(of: chunks))
        // While it holds the large-file slot, nothing else stages beside it.
        XCTAssertFalse(PhotoKitStagingSink(tempStore: tempStore, filename: "OTHER.HEIC").isStaging)
        tempStore.discard(staged)
    }

    func testALargeOriginalThatGrowsBeyondItsKnownSizeIsOnlyHashed() {
        let tempStore = store(maximumBytes: 100)
        let chunks = [Data(count: 150), Data(count: 150)]
        let sink = PhotoKitStagingSink(tempStore: tempStore, filename: "CHANGED.MOV", expectedBytes: 200)
        chunks.forEach(sink.receive)

        let result = sink.finish()

        XCTAssertNil(result.stagedURL, "more bytes than announced means the asset changed; export it again")
        XCTAssertEqual(result.byteCount, 300)
        XCTAssertEqual(result.sha1Digest, digest(of: chunks))
        XCTAssertTrue(files().isEmpty)
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
