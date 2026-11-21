import Foundation
import XCTest

@testable import UploadCore

final class ExactDuplicateMergeJournalTests: XCTestCase {
    func testClearingAnOlderRecordRetainsSameTimeReplacementsWithDifferentPayloads() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory)
        let checker = ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory)
        let move = UploadRemoteLinkMove(from: "duplicate", to: "kept", contentHash: "main-hash")
        let older = ExactDuplicateMergeIntent(
            volumeID: "volume", kept: "kept", contentHash: "main-hash", hashKeyEpoch: "epoch",
            members: [.init(link: "duplicate", moves: [move])], trashedAt: 1_720_000_000,
            successors: ["earlier-edit"])
        let replacements = [
            ExactDuplicateMergeIntent(
                volumeID: older.volumeID, kept: older.kept, contentHash: older.contentHash,
                hashKeyEpoch: older.hashKeyEpoch,
                members: older.members + [.init(link: "another-duplicate", moves: [])],
                trashedAt: older.trashedAt, successors: older.successors),
            ExactDuplicateMergeIntent(
                volumeID: older.volumeID, kept: older.kept, contentHash: older.contentHash,
                hashKeyEpoch: older.hashKeyEpoch,
                members: [
                    .init(
                        link: "duplicate",
                        moves: [move, .init(from: "related", to: "kept-related", contentHash: "related-hash")])
                ],
                trashedAt: older.trashedAt, successors: older.successors),
            ExactDuplicateMergeIntent(
                volumeID: older.volumeID, kept: older.kept, contentHash: older.contentHash,
                hashKeyEpoch: older.hashKeyEpoch, members: older.members,
                trashedAt: older.trashedAt, successors: ["later-edit"]),
        ]

        for replacement in replacements {
            XCTAssertEqual(replacement.key, older.key)
            XCTAssertEqual(replacement.trashedAt, older.trashedAt)
            XCTAssertNotEqual(replacement, older)
            XCTAssertTrue(writer.record([older]))
            XCTAssertEqual(checker.pendingMerges(), [older])
            XCTAssertTrue(writer.record([replacement]))
            XCTAssertEqual(checker.pendingMerges(), [replacement])

            XCTAssertTrue(checker.clear([older]))

            XCTAssertEqual(
                writer.pendingMerges(), [replacement],
                "Clearing the checked record must retain a same-time replacement with a different payload")
            XCTAssertTrue(checker.clear([replacement]), "The exact current record must still clear")
            XCTAssertEqual(writer.pendingMerges(), [])
        }
    }

    // MARK: The file of the journal, as an earlier build writes and reads it

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-journal-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func intent(_ kept: String, successors: [String]? = ["earlier-edit"]) -> ExactDuplicateMergeIntent {
        ExactDuplicateMergeIntent(
            volumeID: "volume", kept: kept, contentHash: "main-hash", hashKeyEpoch: "epoch",
            members: [
                .init(
                    link: "duplicate-of-\(kept)", moves: [.init(from: "duplicate", to: kept, contentHash: "main-hash")])
            ],
            trashedAt: 1_720_000_000, successors: successors)
    }

    /// The JSON of `intent("kept")`, keys sorted.
    private let keptJSON = """
        {"contentHash":"main-hash","hashKeyEpoch":"epoch","kept":"kept",\
        "members":[{"link":"duplicate-of-kept","moves":[{"contentHash":"main-hash","from":"duplicate","to":"kept"}]}],\
        "successors":["earlier-edit"],"trashedAt":1720000000,"volumeID":"volume"}
        """

    private func assertFile(
        in directory: URL, holds expected: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            [ExactDuplicateMergeJournalFileStore.fileName],
            "one file", file: file, line: line)
        let url = directory.appendingPathComponent(ExactDuplicateMergeJournalFileStore.fileName)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertEqual(text.utf8.count, expected.utf8.count, "exact length", file: file, line: line)
        XCTAssertEqual(canonicalJSON(text), expected, "exact content", file: file, line: line)
    }

    func testTheJournalIsOneFileThatHoldsExactlyItsEncodedIntentsInOrder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory)

        XCTAssertTrue(store.record([intent("kept")]))
        try assertFile(in: directory, holds: "[\(keptJSON)]")

        XCTAssertTrue(store.record([intent("second")]))
        XCTAssertTrue(store.record([intent("kept", successors: nil)]))
        let expected = try XCTUnwrap(
            String(data: JSONEncoder().encode([intent("second"), intent("kept", successors: nil)]), encoding: .utf8))
        try assertFile(in: directory, holds: canonicalJSON(expected))

        XCTAssertTrue(store.clear([intent("second"), intent("kept", successors: nil)]))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path), [],
            "the last intent removes the file instead of writing an empty list")
    }

    func testAJournalFileOfAnEarlierBuildIsReadBack() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("[\(keptJSON)]".utf8).write(
            to: directory.appendingPathComponent(ExactDuplicateMergeJournalFileStore.fileName))

        let store = ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory)

        XCTAssertEqual(store.pendingMerges(), [intent("kept")])
        XCTAssertEqual(store.prepareForWrites(), .ready)
    }

    // MARK: Writes through the file-system seam

    func testTheJournalWritesAndRemovesItsFileThroughTheSeam() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = StorageFaultFiles()
        let store = ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory, fileSystem: files)
        var writes: [String] = []
        files.watch(failing: [], onStart: { writes.append($0) })

        XCTAssertTrue(store.record([intent("kept")]))
        XCTAssertTrue(store.clear([intent("kept")]))

        let name = ExactDuplicateMergeJournalFileStore.fileName
        XCTAssertEqual(writes, ["replace \(name)", "remove \(name)"])
    }

    func testAFailedWriteKeepsTheFileAndReportsTheFailure() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = StorageFaultFiles()
        let store = ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory, fileSystem: files)
        XCTAssertTrue(store.record([intent("kept")]))
        let file = directory.appendingPathComponent(ExactDuplicateMergeJournalFileStore.fileName)
        let saved = try Data(contentsOf: file)

        files.watch(failing: [1, 2])
        XCTAssertFalse(store.record([intent("second")]), "a failed replacement reports the failure")
        XCTAssertFalse(store.clear([intent("kept")]), "a failed removal reports the failure")
        files.stopWatching()

        XCTAssertEqual(try Data(contentsOf: file), saved)
        XCTAssertEqual(store.pendingMerges(), [intent("kept")])
    }
}
