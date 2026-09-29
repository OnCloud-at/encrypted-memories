import Darwin
import DeviceRootCore
import Foundation
import Testing

@testable import DeviceRootAppleAdapter

private actor JournalCompletionFlag {
    private(set) var isMarked = false
    func mark() { isMarked = true }
}

private struct JournalSyncFailure: Error {}

private final class JournalSyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int32, Bool)] = []

    func record(descriptor: Int32, command: Int32) {
        var metadata = stat()
        let isDirectory =
            Darwin.fstat(descriptor, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFDIR
        lock.withLock { values.append((command, isDirectory)) }
    }

    func snapshot() -> [(Int32, Bool)] { lock.withLock { values } }
}

private func waitForLockAttempt(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 5) == .success
}

@Suite("Device root enrollment journal")
struct DeviceRootEnrollmentFileJournalTests {
    @Test func fallbackRootLocationSurvivesReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = DeviceRootIdentity(
            deviceUID: "my-files-container", rootFolderUID: "app-folder",
            incarnation: "claim", location: .myFiles)
        let first = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        try await first.select(root)

        let reopened = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await reopened.selectedRoot() == root)
    }

    @Test func versionTwoSelectionUpgradesInPlaceAsComputer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("device-root-enrollment.json")
        let previous = Data(
            """
            {"version":2,"selectedDeviceUID":"device","selectedRootFolderUID":"folder",\
            "selectedIncarnation":"claim"}
            """.utf8)
        try previous.write(to: file)

        let journal = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        let root = DeviceRootIdentity(deviceUID: "device", rootFolderUID: "folder", incarnation: "claim")
        #expect(try await journal.selectedRoot() == root)

        let upgraded = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(upgraded["version"] as? Int == 4)
        #expect(upgraded["selectedLocation"] as? String == "computer")
    }

    @Test func twoJournalInstancesAuthorizeOnlyOneCreate() async throws {
        for _ in 0..<20 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
            let second = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
            async let firstAllowed = first.beginCreateIfAbsent(incarnation: "claim")
            async let secondAllowed = second.beginCreateIfAbsent(incarnation: "claim")
            let outcomes = try await [firstAllowed, secondAllowed]
            #expect(outcomes.filter { $0 }.count == 1)
        }
    }

    @Test func journalWaitsForLockHeldByAnotherProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockFile = directory.appendingPathComponent("device-root-enrollment.lock")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            "import fcntl,sys; f=open(sys.argv[1],'a+'); fcntl.lockf(f,fcntl.LOCK_EX); print('locked',flush=True); sys.stdin.readline()",
            lockFile.path,
        ]
        let input = Pipe()
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            if child.isRunning {
                input.fileHandleForWriting.write(Data("\n".utf8))
                child.waitUntilExit()
            }
        }
        let ready = try #require(try output.fileHandleForReading.read(upToCount: 7))
        #expect(String(decoding: ready, as: UTF8.self) == "locked\n")

        let completed = JournalCompletionFlag()
        let enteredFileLock = DispatchSemaphore(value: 0)
        let journal = DeviceRootEnrollmentFileJournal(
            accountDataDirectory: directory,
            onBeforeFileLock: { enteredFileLock.signal() }, synchronize: nil)
        let attempt = Task {
            let result = try await journal.beginCreateIfAbsent(incarnation: "claim")
            await completed.mark()
            return result
        }
        #expect(await Task.detached { waitForLockAttempt(enteredFileLock) }.value)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!(await completed.isMarked))
        input.fileHandleForWriting.write(Data("\n".utf8))
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #expect(try await attempt.value)
    }

    @Test func versionThreePendingCreateCannotBeMistakenForAnUnsentCreate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("device-root-enrollment.json")
        try Data(
            """
            {"version":3,"pendingIncarnation":"claim","pendingLocation":"computer"}
            """.utf8
        ).write(to: file)

        let journal = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await journal.pendingCreate()?.dispatchAttempted == true)
        #expect(!(try await journal.abortPreparedCreate(location: .computer, incarnation: "claim")))
        let upgraded = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(upgraded["version"] as? Int == 4)
        #expect(upgraded["pendingDispatchAttempted"] as? Bool == true)
    }

    @Test func failedDurabilityBarrierDoesNotMakeAnUnsentIntentLookDispatched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = DeviceRootEnrollmentFileJournal(
            accountDataDirectory: directory,
            onBeforeFileLock: nil,
            synchronize: { _, _ in throw JournalSyncFailure() })
        await #expect(throws: JournalSyncFailure.self) {
            try await failing.beginCreateIfAbsent(incarnation: "prepared")
        }

        let restarted = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await restarted.pendingCreate()?.dispatchAttempted == false)
        #expect(try await restarted.abortPreparedCreate(location: .computer, incarnation: "prepared"))
        #expect(try await restarted.pendingCreate() == nil)
    }

    @Test func dispatchReservationUsesFullSyncForFileAndDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = JournalSyncRecorder()
        let journal = DeviceRootEnrollmentFileJournal(
            accountDataDirectory: directory, onBeforeFileLock: nil,
            synchronize: { descriptor, command in
                recorder.record(descriptor: descriptor, command: command)
                return 0
            })
        #expect(try await journal.beginCreateIfAbsent(incarnation: "claim"))
        #expect(
            try await journal.markCreateDispatchAttempted(
                location: .computer, incarnation: "claim"))
        let calls = recorder.snapshot()
        #expect(calls.count == 4)
        #expect(calls.allSatisfy { $0.0 == F_FULLFSYNC })
        #expect(calls.map(\.1) == [false, true, false, true])
        let reopened = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await reopened.pendingCreate()?.dispatchAttempted == true)
    }

    @Test func productionSyncForwardsTheCommandToDarwin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("journal-probe")
        try Data("probe".utf8).write(to: file)
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW)
        #expect(descriptor >= 0)
        defer { if descriptor >= 0 { _ = Darwin.close(descriptor) } }

        #expect(DeviceRootEnrollmentFileJournal.systemSync(descriptor, command: -1) == -1)
        #expect(DeviceRootEnrollmentFileJournal.systemSync(descriptor, command: F_FULLFSYNC) == 0)
    }

    @Test func failedSystemCallReturnStopsEnrollmentJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = DeviceRootEnrollmentFileJournal(
            accountDataDirectory: directory, onBeforeFileLock: nil,
            synchronize: { _, _ in
                errno = EIO
                return -1
            })
        do {
            _ = try await failing.beginCreateIfAbsent(incarnation: "claim")
            Issue.record("A failed full-sync syscall must block enrollment")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSPOSIXErrorDomain)
            #expect(failure.code == Int(EIO))
        }
    }

    @Test func failedDispatchBarrierNeverPermitsCrashRecoveryToAssumeNoCreate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await first.beginCreateIfAbsent(incarnation: "claim"))
        let failing = DeviceRootEnrollmentFileJournal(
            accountDataDirectory: directory,
            onBeforeFileLock: nil,
            synchronize: { _, _ in throw JournalSyncFailure() })
        await #expect(throws: JournalSyncFailure.self) {
            try await failing.markCreateDispatchAttempted(
                location: .computer, incarnation: "claim")
        }

        let restarted = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await restarted.pendingCreate()?.dispatchAttempted == true)
        #expect(!(try await restarted.abortPreparedCreate(location: .computer, incarnation: "claim")))
    }

    @Test func failedDirectoryBarrierNeverAuthorizesRemoteCreate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await first.beginCreateIfAbsent(incarnation: "claim"))
        let failing = DeviceRootEnrollmentFileJournal(
            accountDataDirectory: directory, onBeforeFileLock: nil,
            synchronize: { descriptor, _ in
                var metadata = stat()
                guard Darwin.fstat(descriptor, &metadata) == 0 else { throw JournalSyncFailure() }
                if metadata.st_mode & S_IFMT == S_IFDIR { throw JournalSyncFailure() }
                return 0
            })
        await #expect(throws: JournalSyncFailure.self) {
            try await failing.markCreateDispatchAttempted(
                location: .computer, incarnation: "claim")
        }

        let restarted = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await restarted.pendingCreate()?.dispatchAttempted == true)
        #expect(!(try await restarted.abortPreparedCreate(location: .computer, incarnation: "claim")))
    }

    @Test func unreadableJournalLocationFailsClosed() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("file, not directory".utf8).write(to: parent)
        let journal = DeviceRootEnrollmentFileJournal(accountDataDirectory: parent)
        await #expect(throws: (any Error).self) { try await journal.selectedRoot() }
        await #expect(throws: (any Error).self) {
            try await journal.beginCreateIfAbsent(incarnation: "claim")
        }
    }

    @Test func pendingCreateSurvivesReopenBeforeRemoteCall() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await first.beginCreateIfAbsent(incarnation: "claim"))

        let reopened = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await reopened.pendingCreate()?.incarnation == "claim")
        #expect(try await reopened.pendingCreate()?.createdDevice == nil)
        #expect(!(try await reopened.beginCreateIfAbsent(incarnation: "other")))
    }

    @Test func onlyMatchingUnsentIntentCanBeAbortedAcrossInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let creator = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        let canceller = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await creator.beginCreateIfAbsent(incarnation: "first"))
        #expect(
            !(try await canceller.abortCreateBeforeRemoteCall(
                location: .computer, incarnation: "other")))
        #expect(try await creator.pendingCreate()?.incarnation == "first")
        #expect(
            try await canceller.abortCreateBeforeRemoteCall(
                location: .computer, incarnation: "first"))

        let reopened = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await reopened.pendingCreate() == nil)
        #expect(try await reopened.beginCreateIfAbsent(incarnation: "second"))
        #expect(
            try await reopened.markCreateDispatchAttempted(
                location: .computer, incarnation: "second"))
        try await reopened.recordCreatedDevice(
            .init(deviceUID: "device", rootFolderUID: "folder"))
        #expect(
            !(try await creator.abortCreateBeforeRemoteCall(
                location: .computer, incarnation: "second")))
    }

    @Test func preparedIntentCanBeAbortedAfterRestartButDispatchedIntentCannot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await first.beginCreateIfAbsent(incarnation: "prepared"))

        let reopened = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await reopened.pendingCreate()?.dispatchAttempted == false)
        #expect(
            try await reopened.abortPreparedCreate(
                location: .computer, incarnation: "prepared"))
        #expect(try await reopened.beginCreateIfAbsent(incarnation: "dispatched"))
        #expect(
            try await reopened.markCreateDispatchAttempted(
                location: .computer, incarnation: "dispatched"))

        let afterCrash = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await afterCrash.pendingCreate()?.dispatchAttempted == true)
        #expect(
            !(try await afterCrash.abortPreparedCreate(
                location: .computer, incarnation: "dispatched")))
        #expect(try await afterCrash.pendingCreate()?.incarnation == "dispatched")
    }

    @Test func deviceCheckpointSurvivesBeforeClaimPublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = DeviceRootUnclaimedDevice(deviceUID: "device", rootFolderUID: "folder")
        let first = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await first.beginCreateIfAbsent(incarnation: "claim"))
        #expect(
            try await first.markCreateDispatchAttempted(
                location: .computer, incarnation: "claim"))
        try await first.recordCreatedDevice(device)

        let reopened = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await reopened.pendingCreate() == .init(incarnation: "claim", createdDevice: device))
    }

    @Test func selectedRootAndSettlementSurviveReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DeviceRootIdentity(deviceUID: "device", rootFolderUID: "folder", incarnation: "claim")
        let first = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await first.beginCreateIfAbsent(incarnation: "claim"))
        #expect(
            try await first.markCreateDispatchAttempted(
                location: .computer, incarnation: "claim"))
        try await first.recordCreatedDevice(.init(deviceUID: "device", rootFolderUID: "folder"))
        try await first.select(identity)

        let interrupted = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await interrupted.selectedRoot() == identity)
        #expect(try await interrupted.pendingCreate() != nil)
        try await interrupted.finishCreate()

        let settled = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await settled.selectedRoot() == identity)
        #expect(try await settled.pendingCreate() == nil)
    }

    @Test func discoveryCannotSelectAcrossASecondJournalCreateIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let discoverer = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        let creator = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        let root = DeviceRootIdentity(deviceUID: "device", rootFolderUID: "folder", incarnation: "claim")

        #expect(try await creator.beginCreateIfAbsent(incarnation: "claim"))
        #expect(!(try await discoverer.selectIfNoPending(root)))
        #expect(try await discoverer.selectedRoot() == nil)
        #expect(try await creator.pendingCreate()?.incarnation == "claim")
    }

    @Test func damagedJournalDoesNotBecomeAnEmptyAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await first.beginCreateIfAbsent(incarnation: "claim"))
        try Data("broken".utf8).write(to: directory.appendingPathComponent("device-root-enrollment.json"))

        let reopened = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        await #expect(throws: (any Error).self) { try await reopened.selectedRoot() }
        await #expect(throws: (any Error).self) {
            try await reopened.beginCreateIfAbsent(incarnation: "claim")
        }
    }
}
