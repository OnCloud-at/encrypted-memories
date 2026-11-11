import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// The files of the revert and the series dissolution journals, as an earlier build writes and reads them: one file per
/// photo, named by the SHA-256 of "volume/node", that holds exactly the encoded journal. A build that writes the same
/// names and bytes stays readable by an earlier build. `JSONEncoder` varies the key order, so the bytes are compared by
/// their length and their content with sorted keys.
final class PhotoJournalFileFormatTests: XCTestCase {
    private var accountDirectory: URL!

    override func setUpWithError() throws {
        accountDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-journal-file-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: accountDirectory)
    }

    private let main = PhotoUID(volumeID: "volume", nodeID: "main")
    private let second = PhotoUID(volumeID: "volume", nodeID: "second")
    private let third = PhotoUID(volumeID: "volume", nodeID: "third")
    private let copy = PhotoUID(volumeID: "volume", nodeID: "copy")
    private let frame1 = PhotoUID(volumeID: "volume", nodeID: "frame-1")
    private let frame2 = PhotoUID(volumeID: "volume", nodeID: "frame-2")

    /// SHA-256 of "volume/main", "volume/second" and "volume/third".
    private let mainFile = "ec6fce6f7ea3a800d91ebe87211dcd007ff6f79b5d18f4748d036003ec145774.json"
    private let secondFile = "4e491fd5b8512cb68e74ba549980c6feee77b6a7d4c7b18d94881c456d3f780e.json"
    private let thirdFile = "8c78e290afbe8ef90b844c24e3e0fd355a80200ac305cf08ca9fa86787926b50.json"

    private var revertJournal: EditedOriginalRevertJournal {
        EditedOriginalRevertJournal(
            editedMainUID: main, originalLinkID: "original", restoredName: "IMG_0001.HEIC", copyUID: copy,
            favoriteDone: true, addedAlbumIDs: ["album-1", "album-2"], phase: .trashingEdit)
    }

    private let revertJSON = """
        {"addedAlbumIDs":["album-1","album-2"],"copyUID":{"nodeID":"copy","volumeID":"volume"},\
        "editedMainUID":{"nodeID":"main","volumeID":"volume"},"favoriteDone":true,"originalLinkID":"original",\
        "phase":"trashingEdit","restoredName":"IMG_0001.HEIC"}
        """

    private var seriesJournal: SeriesDissolutionJournal {
        SeriesDissolutionJournal(
            seriesMainUID: main, seriesUIDs: [main, frame1, frame2],
            favorites: [
                .init(memberUID: frame1, copyUID: copy, favoriteTagAdded: true, addedAlbumIDs: ["album-1"]),
                .init(memberUID: frame2),
            ],
            phase: .trashingSeries)
    }

    private let seriesJSON = """
        {"favorites":[{"addedAlbumIDs":["album-1"],"copyUID":{"nodeID":"copy","volumeID":"volume"},\
        "favoriteTagAdded":true,"memberUID":{"nodeID":"frame-1","volumeID":"volume"}},\
        {"addedAlbumIDs":[],"favoriteTagAdded":false,"memberUID":{"nodeID":"frame-2","volumeID":"volume"}}],\
        "phase":"trashingSeries","seriesMainUID":{"nodeID":"main","volumeID":"volume"},\
        "seriesUIDs":[{"nodeID":"main","volumeID":"volume"},{"nodeID":"frame-1","volumeID":"volume"},\
        {"nodeID":"frame-2","volumeID":"volume"}]}
        """

    private var revertDirectory: URL { accountDirectory.appendingPathComponent("edited-original-revert") }
    private var seriesDirectory: URL { accountDirectory.appendingPathComponent("series-dissolution") }

    // MARK: Writing

    func testARevertJournalIsSavedAsExactlyItsEncodedBytesInTheFileOfItsPhoto() throws {
        let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: accountDirectory)
        try store.save(EditedOriginalRevertJournal(editedMainUID: main, originalLinkID: "first"))
        try store.save(revertJournal)

        XCTAssertEqual(try fileNames(in: revertDirectory), [mainFile], "a later save replaces the file of the photo")
        try assertFile(revertDirectory.appendingPathComponent(mainFile), holds: revertJSON)
    }

    func testASeriesJournalIsSavedAsExactlyItsEncodedBytesInTheFileOfItsMainPhoto() throws {
        let store = SeriesDissolutionJournalFileStore(accountDataDirectory: accountDirectory)
        try store.save(SeriesDissolutionJournal(seriesMainUID: main, seriesUIDs: [main], favorites: []))
        try store.save(seriesJournal)

        XCTAssertEqual(try fileNames(in: seriesDirectory), [mainFile], "a later save replaces the file of the series")
        try assertFile(seriesDirectory.appendingPathComponent(mainFile), holds: seriesJSON)
    }

    func testRemovingAJournalDeletesOnlyTheFileOfItsPhoto() throws {
        let revert = EditedOriginalRevertJournalFileStore(accountDataDirectory: accountDirectory)
        try revert.save(revertJournal)
        try revert.save(EditedOriginalRevertJournal(editedMainUID: second, originalLinkID: "original"))
        try revert.remove(forEditedMain: main)
        try revert.remove(forEditedMain: third)
        XCTAssertEqual(try fileNames(in: revertDirectory), [secondFile])

        let series = SeriesDissolutionJournalFileStore(accountDataDirectory: accountDirectory)
        try series.save(seriesJournal)
        try series.save(SeriesDissolutionJournal(seriesMainUID: second, seriesUIDs: [second], favorites: []))
        try series.remove(forSeries: main)
        try series.remove(forSeries: third)
        XCTAssertEqual(try fileNames(in: seriesDirectory), [secondFile])
    }

    // MARK: Reading files of an earlier build

    func testARevertJournalFileOfAnEarlierBuildIsReadBack() throws {
        try write(revertJSON, to: revertDirectory.appendingPathComponent(mainFile))
        let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: accountDirectory)

        XCTAssertEqual(try store.journal(forEditedMain: main), revertJournal)
        XCTAssertEqual(try store.decodableJournal(forEditedMain: main), revertJournal)
        XCTAssertEqual(try store.pendingJournals(), [revertJournal])
    }

    func testASeriesJournalFileOfAnEarlierBuildIsReadBack() throws {
        try write(seriesJSON, to: seriesDirectory.appendingPathComponent(mainFile))
        let store = SeriesDissolutionJournalFileStore(accountDataDirectory: accountDirectory)

        XCTAssertEqual(try store.journal(forSeries: main), seriesJournal)
        XCTAssertEqual(try store.pendingJournals(), [seriesJournal])
    }

    func testPendingJournalsComeInTheOrderOfTheirFileNamesAndOnlyFromJSONFiles() throws {
        let revert = EditedOriginalRevertJournalFileStore(accountDataDirectory: accountDirectory)
        let series = SeriesDissolutionJournalFileStore(accountDataDirectory: accountDirectory)
        for uid in [main, second, third] {
            try revert.save(EditedOriginalRevertJournal(editedMainUID: uid, originalLinkID: "original"))
            try series.save(SeriesDissolutionJournal(seriesMainUID: uid, seriesUIDs: [uid], favorites: []))
        }
        try write("not a journal", to: revertDirectory.appendingPathComponent("notes.txt"))
        try write("not a journal", to: seriesDirectory.appendingPathComponent("notes.txt"))

        // File name order: second (4e49…), third (8c78…), main (ec6f…).
        XCTAssertEqual(try revert.pendingJournals().map(\.editedMainUID), [second, third, main])
        XCTAssertEqual(try series.pendingJournals().map(\.seriesMainUID), [second, third, main])
    }

    func testAnAccountWithoutJournalsHasNoDirectoryAndNoJournal() throws {
        let revert = EditedOriginalRevertJournalFileStore(accountDataDirectory: accountDirectory)
        let series = SeriesDissolutionJournalFileStore(accountDataDirectory: accountDirectory)

        XCTAssertNil(try revert.journal(forEditedMain: main))
        XCTAssertNil(try revert.decodableJournal(forEditedMain: main))
        XCTAssertEqual(try revert.pendingJournals(), [])
        XCTAssertNil(try series.journal(forSeries: main))
        XCTAssertEqual(try series.pendingJournals(), [])
        try revert.remove(forEditedMain: main)
        try series.remove(forSeries: main)
        XCTAssertEqual(try fileNames(in: accountDirectory), [], "reads and removals create no directory")
    }

    func testAnUndecodableSeriesJournalStopsEveryRead() throws {
        // The revert journal skips such a file (EditedOriginalRevertJournalTests); the series journal throws.
        let store = SeriesDissolutionJournalFileStore(accountDataDirectory: accountDirectory)
        try store.save(SeriesDissolutionJournal(seriesMainUID: second, seriesUIDs: [second], favorites: []))
        try write("invalid", to: seriesDirectory.appendingPathComponent(mainFile))

        XCTAssertThrowsError(try store.journal(forSeries: main))
        XCTAssertThrowsError(try store.pendingJournals())
    }

    func testASeriesJournalPathThatCannotBeReadThrowsAndStays() throws {
        // The revert journal behaves the same (EditedOriginalRevertJournalTests).
        let store = SeriesDissolutionJournalFileStore(accountDataDirectory: accountDirectory)
        let unreadable = seriesDirectory.appendingPathComponent(mainFile)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.journal(forSeries: main))
        XCTAssertThrowsError(try store.pendingJournals())
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unreadable.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    // MARK: Writes through the file-system seam

    func testARevertJournalWritesAndRemovesItsFileThroughTheSeam() throws {
        let files = StorageFaultFiles()
        let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: accountDirectory, fileSystem: files)
        var writes: [String] = []
        files.watch(failing: [], onStart: { writes.append($0) })
        try store.save(revertJournal)
        try store.remove(forEditedMain: main)
        XCTAssertEqual(writes, ["replace \(mainFile)", "remove \(mainFile)"])
    }

    func testASeriesJournalWritesAndRemovesItsFileThroughTheSeam() throws {
        let files = StorageFaultFiles()
        let store = SeriesDissolutionJournalFileStore(accountDataDirectory: accountDirectory, fileSystem: files)
        var writes: [String] = []
        files.watch(failing: [], onStart: { writes.append($0) })
        try store.save(seriesJournal)
        try store.remove(forSeries: main)
        XCTAssertEqual(writes, ["replace \(mainFile)", "remove \(mainFile)"])
    }

    func testAFailedSaveKeepsTheEarlierFileAndAFailedRemovalKeepsTheFile() throws {
        let files = StorageFaultFiles()
        let revert = EditedOriginalRevertJournalFileStore(accountDataDirectory: accountDirectory, fileSystem: files)
        let series = SeriesDissolutionJournalFileStore(accountDataDirectory: accountDirectory, fileSystem: files)
        try revert.save(EditedOriginalRevertJournal(editedMainUID: main, originalLinkID: "first"))
        try series.save(SeriesDissolutionJournal(seriesMainUID: main, seriesUIDs: [main], favorites: []))
        let revertFile = revertDirectory.appendingPathComponent(mainFile)
        let seriesFile = seriesDirectory.appendingPathComponent(mainFile)
        let revertBytes = try Data(contentsOf: revertFile)
        let seriesBytes = try Data(contentsOf: seriesFile)

        files.watch(failing: [1, 2, 3, 4])
        XCTAssertThrowsError(try revert.save(revertJournal))
        XCTAssertThrowsError(try series.save(seriesJournal))
        XCTAssertThrowsError(try revert.remove(forEditedMain: main))
        XCTAssertThrowsError(try series.remove(forSeries: main))
        files.stopWatching()

        XCTAssertEqual(try Data(contentsOf: revertFile), revertBytes)
        XCTAssertEqual(try Data(contentsOf: seriesFile), seriesBytes)
    }

    func testARemovalThatCannotReachTheDirectoryThrowsInsteadOfReadingAsNoJournal() throws {
        let store = EditedOriginalRevertJournalFileStore(accountDataDirectory: accountDirectory)
        try store.save(revertJournal)
        // Without search permission the file cannot be found or removed; that is no missing journal.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: revertDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: revertDirectory.path) }

        XCTAssertThrowsError(try store.remove(forEditedMain: main))
    }

    // MARK: Helpers

    private func fileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func assertFile(
        _ url: URL, holds expected: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertEqual(text.utf8.count, expected.utf8.count, "exact length", file: file, line: line)
        XCTAssertEqual(canonicalJSON(text), expected, "exact content", file: file, line: line)
    }
}
