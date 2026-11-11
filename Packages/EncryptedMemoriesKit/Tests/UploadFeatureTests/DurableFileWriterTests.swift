import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// The durable file writer of the journals (#1149): appends keep no part of a failed write, and the writes go through
/// the file-system seam that the fault-injection sweep fails.
final class DurableFileWriterTests: XCTestCase {
    private var directory: URL!
    private var files: StorageFaultFiles!
    private var writes: [String] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-file-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files = StorageFaultFiles()
        writes = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var url: URL { directory.appendingPathComponent("log.jsonl") }
    private var bytes: Data? { try? Data(contentsOf: url) }

    /// Fails the writes with these numbers, counted from now, and records every write from now.
    private func failWrites(_ failing: Set<Int>) {
        writes = []
        files.watch(failing: failing, onStart: { [unowned self] in writes.append($0) })
    }

    func testTheFirstAppendCreatesTheFileInOneReplacement() throws {
        var writer = DurableFileWriter(url: url, fileSystem: files)
        failWrites([])

        XCTAssertTrue(try writer.append(Data("a\n".utf8)), "the append created the file")

        XCTAssertEqual(bytes, Data("a\n".utf8))
        XCTAssertEqual(writes, ["replace log.jsonl"])
    }

    func testALaterAppendWritesItsBytesAtTheEnd() throws {
        var writer = DurableFileWriter(url: url, fileSystem: files)
        _ = try writer.append(Data("a\n".utf8))
        failWrites([])

        XCTAssertFalse(try writer.append(Data("bb\n".utf8)), "the file existed")

        XCTAssertEqual(bytes, Data("a\nbb\n".utf8))
        XCTAssertEqual(writes, ["append log.jsonl"])
    }

    func testAFailedAppendKeepsNoPartOfItsBytes() throws {
        var writer = DurableFileWriter(url: url, fileSystem: files)
        _ = try writer.append(Data("a\n".utf8))
        failWrites([1])

        XCTAssertThrowsError(try writer.append(Data("bbbb\n".utf8)))

        XCTAssertEqual(bytes, Data("a\n".utf8), "the half-written bytes are cut off")
        XCTAssertEqual(writes, ["append log.jsonl", "truncate log.jsonl"])
        XCTAssertFalse(writer.writeFailed)
        failWrites([])
        _ = try writer.append(Data("c\n".utf8))
        XCTAssertEqual(bytes, Data("a\nc\n".utf8), "the next append starts on a clean end")
    }

    func testAnAppendWhoseBytesCannotBeCutOffStopsTheWriter() throws {
        var writer = DurableFileWriter(url: url, fileSystem: files)
        _ = try writer.append(Data("a\n".utf8))
        failWrites([1, 2])

        XCTAssertThrowsError(try writer.append(Data("bbbb\n".utf8)))

        XCTAssertTrue(writer.writeFailed)
        XCTAssertEqual(bytes, Data("a\nbb".utf8), "the half line stays, so nothing may follow it")
        failWrites([])
        XCTAssertThrowsError(try writer.append(Data("c\n".utf8))) { error in
            XCTAssertTrue(error is DurableFileWriter.Unusable)
        }
        XCTAssertEqual(bytes, Data("a\nbb".utf8))
        XCTAssertEqual(writes, [], "a stopped writer writes nothing")
    }

    func testAReplacementWritesTheWholeFileInOneStep() throws {
        var writer = DurableFileWriter(url: url, fileSystem: files)
        _ = try writer.append(Data("a\nb\n".utf8))
        failWrites([])

        try writer.replace(with: Data("c\n".utf8))

        XCTAssertEqual(bytes, Data("c\n".utf8))
        XCTAssertEqual(writes, ["replace log.jsonl"])
    }

    /// An atomic replacement writes a new file and swaps it in, so a stop during the write leaves the earlier file
    /// whole. The swap shows as a new file number; a write in place keeps the number.
    func testTheLocalReplacementSwapsInANewFile() throws {
        try Data("a\n".utf8).write(to: url)
        let fileNumber = { try FileManager.default.attributesOfItem(atPath: self.url.path)[.systemFileNumber] as? Int }
        let before = try fileNumber()

        try LocalDurableFileSystem().replace(url, with: Data("b\n".utf8))

        XCTAssertEqual(bytes, Data("b\n".utf8))
        XCTAssertNotEqual(try fileNumber(), before, "the replacement is a new file, not a write into the old one")
    }

    // MARK: - The edit replacement journal on the seam

    private let asset = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-1")

    func testAFailedJournalWriteKeepsTheEntryAndTheLog() throws {
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory, fileSystem: files))
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "a"), for: asset)
        let logURL = directory.appendingPathComponent(EditReplacementJournalFileStore.logFileName)
        let log = try Data(contentsOf: logURL)
        failWrites([1])

        XCTAssertThrowsError(try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "b"), for: asset))

        XCTAssertEqual(
            writes,
            [
                "append \(EditReplacementJournalFileStore.logFileName)",
                "truncate \(EditReplacementJournalFileStore.logFileName)",
            ])
        XCTAssertEqual(try Data(contentsOf: logURL), log, "the log keeps no part of the failed line")
        XCTAssertEqual(journal.entry(for: asset).superseded.map(\.nodeID), ["a"])
        failWrites([])
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "c"), for: asset)
        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(reopened.entry(for: asset).superseded.map(\.nodeID), ["a", "c"])
    }

    func testAJournalWhoseFailedLineCannotBeCutOffAcceptsNoFurtherChange() throws {
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory, fileSystem: files))
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "a"), for: asset)
        failWrites([1, 2])
        XCTAssertThrowsError(try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "b"), for: asset))
        failWrites([])

        XCTAssertThrowsError(try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "c"), for: asset)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                UploadError.backend("Edit replacement journal could not be written").localizedDescription)
        }
        XCTAssertEqual(writes, [], "the journal writes nothing after the half line")
        XCTAssertEqual(journal.entry(for: asset).superseded.map(\.nodeID), ["a"])
    }

    func testAFailedFirstLineLeavesNoLogAndKeepsNoEntry() throws {
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory, fileSystem: files))
        let logURL = directory.appendingPathComponent(EditReplacementJournalFileStore.logFileName)
        failWrites([1])

        XCTAssertThrowsError(try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "a"), for: asset))

        XCTAssertEqual(writes, ["replace \(EditReplacementJournalFileStore.logFileName)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path), "the failed replacement wrote no log")
        XCTAssertTrue(journal.entry(for: asset).isEmpty, "a change that is not in the log is not kept in memory")
        failWrites([])
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "b"), for: asset)
        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(reopened.entry(for: asset).superseded.map(\.nodeID), ["b"])
    }

    /// Today's behavior, kept unchanged: a barrier write that fails after the first line is ignored, and the next open
    /// places the barrier. Whether it should throw is an open owner decision on #1149.
    func testAFailedBarrierAfterTheFirstLineIsIgnoredAsBefore() throws {
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory, fileSystem: files))
        let barrierURL = directory.appendingPathComponent(EditReplacementJournalFileStore.fileName)
        failWrites([2])

        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "a"), for: asset)

        XCTAssertEqual(
            writes,
            [
                "replace \(EditReplacementJournalFileStore.logFileName)",
                "replace \(EditReplacementJournalFileStore.fileName)",
            ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: barrierURL.path))
        XCTAssertEqual(journal.entry(for: asset).superseded.map(\.nodeID), ["a"])
        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(reopened.entry(for: asset).superseded.map(\.nodeID), ["a"])
        XCTAssertEqual(try? Data(contentsOf: barrierURL), EditReplacementJournalFileStore.earlierBuildBarrier)
    }

    func testAStoppedJournalReportsItsOwnErrorBeforeItEncodesTheChange() throws {
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory, fileSystem: files))
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "a"), for: asset)
        failWrites([1, 2])
        XCTAssertThrowsError(try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "b"), for: asset))
        failWrites([])

        // A date that is not a number cannot be encoded; the stopped log must answer first.
        XCTAssertThrowsError(
            try journal.startDeletionCheck(at: Date(timeIntervalSinceReferenceDate: .nan), for: asset)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                UploadError.backend("Edit replacement journal could not be written").localizedDescription)
        }
        XCTAssertEqual(writes, [])
    }

    func testTheBarrierForEarlierBuildsGoesThroughTheSeam() throws {
        failWrites([])
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory, fileSystem: files))

        try journal.recordUpload(edited: true, for: asset)

        XCTAssertEqual(
            writes,
            [
                "replace \(EditReplacementJournalFileStore.logFileName)",
                "replace \(EditReplacementJournalFileStore.fileName)",
            ])
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent(EditReplacementJournalFileStore.fileName)),
            EditReplacementJournalFileStore.earlierBuildBarrier)
    }

    func testOpeningALogWithACutOffLineRewritesItThroughTheSeam() throws {
        let other = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-2")
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory, fileSystem: files))
        try journal.recordUpload(edited: true, for: asset)
        try journal.recordUpload(edited: true, for: other)
        let logURL = directory.appendingPathComponent(EditReplacementJournalFileStore.logFileName)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"key":"photo"#.utf8))
        try handle.close()
        let cutOff = try Data(contentsOf: logURL)

        failWrites([1])
        XCTAssertNil(
            EditReplacementJournalFileStore(accountDataDirectory: directory, fileSystem: files),
            "a log that cannot be rewritten opens no journal")
        XCTAssertEqual(writes, ["replace \(EditReplacementJournalFileStore.logFileName)"])
        XCTAssertEqual(try Data(contentsOf: logURL), cutOff, "the failed rewrite keeps the log")

        failWrites([])
        let reopened = try XCTUnwrap(
            EditReplacementJournalFileStore(accountDataDirectory: directory, fileSystem: files))
        XCTAssertEqual(writes, ["replace \(EditReplacementJournalFileStore.logFileName)"])
        XCTAssertEqual(reopened.entry(for: asset), journal.entry(for: asset))
        XCTAssertEqual(reopened.entry(for: other), journal.entry(for: other))
        XCTAssertEqual(try Data(contentsOf: logURL).last, UInt8(ascii: "\n"), "the cut-off line is gone")
    }
}
