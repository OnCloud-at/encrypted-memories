import DeviceRootCore
import Foundation
import Testing

@testable import DeviceRootAppleAdapter

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
        #expect(upgraded["version"] as? Int == 3)
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

    @Test func deviceCheckpointSurvivesBeforeClaimPublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = DeviceRootUnclaimedDevice(deviceUID: "device", rootFolderUID: "folder")
        let first = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        #expect(try await first.beginCreateIfAbsent(incarnation: "claim"))
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
