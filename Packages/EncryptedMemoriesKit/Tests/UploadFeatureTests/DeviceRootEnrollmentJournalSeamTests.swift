import DeviceRootCore
import Foundation
import PhotosCore
import XCTest

@testable import DeviceRootAppleAdapter

/// The device root enrollment journal writes its file through the durable file seam (#1149) and syncs the file and its
/// directory after each write: the dispatch reservation must survive a power loss before a remote create starts. A
/// sync that fails stops the step, and the record it wrote tells a restart what may have happened.
final class DeviceRootEnrollmentJournalSeamTests: XCTestCase {
    private var directory: URL!
    private var files: StorageFaultFiles!
    private var writes: [String] = []
    private let fileName = "device-root-enrollment.json"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        files = StorageFaultFiles()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A journal whose writes fail with these numbers, counted from now; every write from now is recorded.
    private func journal(failing: Set<Int> = []) -> DeviceRootEnrollmentFileJournal {
        writes = []
        files.watch(failing: failing, onStart: { [unowned self] in writes.append($0) })
        return DeviceRootEnrollmentFileJournal(
            accountDataDirectory: directory, onBeforeFileLock: nil, fileSystem: files)
    }

    private var reopened: DeviceRootEnrollmentFileJournal {
        DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
    }

    func testEachWriteReplacesTheFileAndSyncsTheFileAndItsDirectory() async throws {
        let journal = journal()
        let began = try await journal.beginCreateIfAbsent(incarnation: "claim")
        let marked = try await journal.markCreateDispatchAttempted(location: .computer, incarnation: "claim")

        XCTAssertTrue(began)
        XCTAssertTrue(marked)
        let step = ["replace \(fileName)", "sync \(fileName)", "sync directory"]
        XCTAssertEqual(writes, step + step)
        let pending = try await reopened.pendingCreate()
        XCTAssertEqual(pending?.dispatchAttempted, true)
    }

    func testAFailedSyncOnBeginDoesNotMakeTheIntentLookDispatched() async throws {
        do {
            _ = try await journal(failing: [2]).beginCreateIfAbsent(incarnation: "prepared")
            XCTFail("a failed sync stops the step")
        } catch is StorageFaultFiles.Full {}

        let pending = try await reopened.pendingCreate()
        XCTAssertEqual(pending?.dispatchAttempted, false)
        let aborted = try await reopened.abortPreparedCreate(location: .computer, incarnation: "prepared")
        XCTAssertTrue(aborted)
        let afterAbort = try await reopened.pendingCreate()
        XCTAssertNil(afterAbort)
    }

    func testAFailedFileSyncOfTheDispatchReservationNeverLetsARestartAssumeNoCreate() async throws {
        let began = try await reopened.beginCreateIfAbsent(incarnation: "claim")
        XCTAssertTrue(began)
        do {
            _ = try await journal(failing: [2]).markCreateDispatchAttempted(location: .computer, incarnation: "claim")
            XCTFail("a failed sync stops the step")
        } catch is StorageFaultFiles.Full {}

        try await assertTheRestartTreatsTheCreateAsDispatched()
    }

    func testAFailedDirectorySyncOfTheDispatchReservationNeverLetsARestartAssumeNoCreate() async throws {
        let began = try await reopened.beginCreateIfAbsent(incarnation: "claim")
        XCTAssertTrue(began)
        do {
            _ = try await journal(failing: [3]).markCreateDispatchAttempted(location: .computer, incarnation: "claim")
            XCTFail("a failed sync stops the step")
        } catch is StorageFaultFiles.Full {}

        XCTAssertEqual(writes, ["replace \(fileName)", "sync \(fileName)", "sync directory"])
        try await assertTheRestartTreatsTheCreateAsDispatched()
    }

    private func assertTheRestartTreatsTheCreateAsDispatched(
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let pending = try await reopened.pendingCreate()
        XCTAssertEqual(pending?.dispatchAttempted, true, file: file, line: line)
        let aborted = try await reopened.abortPreparedCreate(location: .computer, incarnation: "claim")
        XCTAssertFalse(aborted, "a reserved dispatch cannot be aborted", file: file, line: line)
    }
}
