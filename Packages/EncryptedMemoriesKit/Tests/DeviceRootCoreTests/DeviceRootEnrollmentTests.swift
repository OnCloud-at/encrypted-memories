import Foundation
import Testing

@testable import DeviceRootCore

private let rootA = DeviceRootIdentity(deviceUID: "device-a", rootFolderUID: "folder-a", incarnation: "first")
private let rootB = DeviceRootIdentity(deviceUID: "device-b", rootFolderUID: "folder-b", incarnation: "second")
private let deviceA = DeviceRootUnclaimedDevice(deviceUID: "device-a", rootFolderUID: "folder-a")
private let deviceB = DeviceRootUnclaimedDevice(deviceUID: "device-b", rootFolderUID: "folder-b")

private actor Catalog: DeviceRootEnrollmentBackend {
    var candidates: [DeviceRootIdentity]
    var unclaimed: [DeviceRootUnclaimedDevice] = []
    var renamedUnclaimed: [DeviceRootUnclaimedDevice] = []
    var complete = true
    var unreadableClaim = false
    var computerUnavailable = false
    var createCount = 0
    var createFallbackCount = 0
    var failFallbackBeforeCreate = false
    var loseCreateResponse = false
    var loseClaimResponse = false
    var failBeforeClaim = false
    var journalAtCreate: Journal?
    var sawPersistedIntent = false
    var sawPersistedDevice = false
    var pauseNextInventory = false
    var releasePausedInventoryOnCancellation = false
    var inventoryResume: CheckedContinuation<Void, Never>?
    var inventoryEntered: [CheckedContinuation<Void, Never>] = []

    init(candidates: [DeviceRootIdentity] = []) {
        self.candidates = candidates
    }

    func inventory() async throws -> DeviceRootCandidateInventory {
        if computerUnavailable { throw DeviceRootOperationError.unsupported }
        if pauseNextInventory {
            pauseNextInventory = false
            if releasePausedInventoryOnCancellation {
                await withTaskCancellationHandler {
                    await waitForInventoryRelease()
                } onCancel: {
                    Task { await self.releaseInventory() }
                }
            } else {
                await waitForInventoryRelease()
            }
        }
        return DeviceRootCandidateInventory(
            verifiedCandidates: candidates, unclaimedCandidates: unclaimed,
            isComplete: complete, hasUnverifiedCandidate: unreadableClaim)
    }

    func inventory(location: DeviceRootLocation) async throws -> DeviceRootCandidateInventory {
        if location == .computer, computerUnavailable {
            throw DeviceRootOperationError.unsupported
        }
        return DeviceRootCandidateInventory(
            verifiedCandidates: candidates.filter { $0.location == location },
            unclaimedCandidates: unclaimed.filter { $0.location == location },
            isComplete: complete, hasUnverifiedCandidate: unreadableClaim)
    }

    func inventoryForExplicitFallback() async throws -> DeviceRootCandidateInventory {
        if computerUnavailable { return try await inventory(location: .myFiles) }
        return try await inventory()
    }

    func inventoryIncludingKnown(
        _ device: DeviceRootUnclaimedDevice
    ) async throws
        -> DeviceRootCandidateInventory
    {
        let base =
            try await
            (device.location == .myFiles
            ? inventoryForExplicitFallback() : inventory())
        return DeviceRootCandidateInventory(
            verifiedCandidates: base.verifiedCandidates,
            unclaimedCandidates: base.unclaimedCandidates
                + (renamedUnclaimed.contains(device) ? [device] : []),
            isComplete: base.isComplete,
            hasUnverifiedCandidate: base.hasUnverifiedCandidate)
    }

    func createDevice() async throws -> DeviceRootUnclaimedDevice {
        if let journalAtCreate {
            sawPersistedIntent = try await journalAtCreate.pendingCreate() != nil
        }
        createCount += 1
        unclaimed.append(deviceA)
        if loseCreateResponse { throw CancellationError() }
        return deviceA
    }

    func createFallbackFolder() async throws -> DeviceRootUnclaimedDevice {
        if failFallbackBeforeCreate { throw DeviceRootOperationError.notDispatched }
        if let journalAtCreate {
            sawPersistedIntent = try await journalAtCreate.pendingCreate()?.location == .myFiles
        }
        createFallbackCount += 1
        let folder = DeviceRootUnclaimedDevice(
            deviceUID: "my-files", rootFolderUID: "fallback-folder", location: .myFiles)
        unclaimed.append(folder)
        if loseCreateResponse { throw CancellationError() }
        return folder
    }

    func ensureClaim(
        for device: DeviceRootUnclaimedDevice, incarnation: String
    ) async throws
        -> DeviceRootIdentity
    {
        if let journalAtCreate {
            sawPersistedDevice = try await journalAtCreate.pendingCreate()?.createdDevice == device
        }
        if failBeforeClaim { throw CancellationError() }
        let identity = DeviceRootIdentity(
            deviceUID: device.deviceUID, rootFolderUID: device.rootFolderUID,
            incarnation: incarnation, location: device.location)
        unclaimed.removeAll { $0 == device }
        renamedUnclaimed.removeAll { $0 == device }
        if !candidates.contains(identity) { candidates.append(identity) }
        if loseClaimResponse { throw CancellationError() }
        return identity
    }

    func count() -> Int { createCount }
    func fallbackCount() -> Int { createFallbackCount }
    func failNextFallbackPreparation() { failFallbackBeforeCreate = true }
    func allowFallbackPreparation() { failFallbackBeforeCreate = false }
    func sawIntent() -> Bool { sawPersistedIntent }
    func sawDeviceCheckpoint() -> Bool { sawPersistedDevice }
    func pauseInventoryOnce() { pauseNextInventory = true }
    func waitForPausedInventory() async {
        if inventoryResume != nil { return }
        await withCheckedContinuation { inventoryEntered.append($0) }
    }
    func releaseInventory() {
        inventoryResume?.resume()
        inventoryResume = nil
    }
    private func waitForInventoryRelease() async {
        await withCheckedContinuation { continuation in
            inventoryResume = continuation
            for waiter in inventoryEntered { waiter.resume() }
            inventoryEntered.removeAll()
        }
    }
    func releaseInventoryOnCancellation() { releasePausedInventoryOnCancellation = true }
    func renameUnclaimed(_ device: DeviceRootUnclaimedDevice) {
        unclaimed.removeAll { $0 == device }
        renamedUnclaimed.append(device)
    }
}

private actor Journal: DeviceRootEnrollmentJournal {
    var selected: DeviceRootIdentity?
    var pending: DeviceRootCreateIntent?
    var began = 0
    var pauseAfterBegin = false
    var beginResume: CheckedContinuation<Void, Never>?
    var beginEntered: [CheckedContinuation<Void, Never>] = []

    func selectedRoot() async throws -> DeviceRootIdentity? { selected }
    func pendingCreate() async throws -> DeviceRootCreateIntent? { pending }
    func beginCreateIfAbsent(
        location: DeviceRootLocation, incarnation: String
    ) async throws -> Bool {
        guard pending == nil else { return false }
        pending = DeviceRootCreateIntent(
            incarnation: incarnation, createdDevice: nil, location: location,
            dispatchAttempted: false)
        began += 1
        if pauseAfterBegin {
            pauseAfterBegin = false
            await withCheckedContinuation { continuation in
                beginResume = continuation
                for waiter in beginEntered { waiter.resume() }
                beginEntered.removeAll()
            }
        }
        return true
    }
    func markCreateDispatchAttempted(
        location: DeviceRootLocation, incarnation: String
    ) async throws -> Bool {
        guard let pending, pending.location == location, pending.incarnation == incarnation,
            !pending.dispatchAttempted, pending.createdDevice == nil
        else { return false }
        self.pending = DeviceRootCreateIntent(
            incarnation: incarnation, createdDevice: nil, location: location,
            dispatchAttempted: true)
        return true
    }
    func abortPreparedCreate(
        location: DeviceRootLocation, incarnation: String
    ) async throws -> Bool {
        guard selected == nil, let pending, pending.location == location,
            pending.incarnation == incarnation, !pending.dispatchAttempted,
            pending.createdDevice == nil
        else { return false }
        self.pending = nil
        return true
    }
    func recordCreatedDevice(_ device: DeviceRootUnclaimedDevice) async throws {
        guard let pending else { return }
        self.pending = DeviceRootCreateIntent(
            incarnation: pending.incarnation, createdDevice: device,
            location: pending.location)
    }
    func abortCreateBeforeRemoteCall(
        location: DeviceRootLocation, incarnation: String
    ) async throws -> Bool {
        guard selected == nil, let pending, pending.location == location,
            pending.incarnation == incarnation, pending.createdDevice == nil
        else { return false }
        self.pending = nil
        return true
    }
    func select(_ root: DeviceRootIdentity) async throws { selected = root }
    func selectIfNoPending(_ root: DeviceRootIdentity) async throws -> Bool {
        guard pending == nil else { return false }
        if let selected { return selected == root }
        selected = root
        return true
    }
    func finishCreate() async throws { pending = nil }
    func snapshot() -> (DeviceRootIdentity?, DeviceRootCreateIntent?, Int) { (selected, pending, began) }
    func pauseBeginOnce() { pauseAfterBegin = true }
    func waitForBeginPersisted() async {
        if beginResume != nil { return }
        await withCheckedContinuation { beginEntered.append($0) }
    }
    func releaseBegin() {
        beginResume?.resume()
        beginResume = nil
    }
}

@Suite("Device root enrollment")
struct DeviceRootEnrollmentTests {
    @Test func fallbackRootLocationIsPartOfItsIdentity() {
        let fallback = DeviceRootIdentity(
            deviceUID: "container", rootFolderUID: "folder", incarnation: "claim",
            location: .myFiles)
        let computer = DeviceRootIdentity(
            deviceUID: "container", rootFolderUID: "folder", incarnation: "claim")
        #expect(fallback.location == .myFiles)
        #expect(fallback != computer)
    }

    @Test func enrollmentCannotPassAnOverlappingDiscovery() async {
        let catalog = Catalog()
        await catalog.pauseInventoryOnce()
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: Journal())
        let discovery = Task { await coordinator.discover() }
        await catalog.waitForPausedInventory()

        #expect(await coordinator.enroll() == .ambiguous)
        #expect(await catalog.count() == 0)
        await catalog.releaseInventory()
        #expect(await discovery.value == .enrollmentRequired)
    }

    @Test func cancellationDuringInventoryCreatesNeitherIntentNorRoot() async {
        let catalog = Catalog()
        await catalog.pauseInventoryOnce()
        let journal = Journal()
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)
        let enrollment = Task { await coordinator.enroll() }
        await catalog.waitForPausedInventory()

        enrollment.cancel()
        await catalog.releaseInventory()
        #expect(await enrollment.value == .unavailable)
        #expect((await journal.snapshot()).1 == nil)
        #expect((await journal.snapshot()).2 == 0)
        #expect(await catalog.count() == 0)
    }

    @Test func cancellationAfterIntentPersistenceAllowsCleanRestart() async {
        let catalog = Catalog()
        let journal = Journal()
        await journal.pauseBeginOnce()
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)
        let enrollment = Task { await coordinator.enroll() }
        await journal.waitForBeginPersisted()

        enrollment.cancel()
        await journal.releaseBegin()
        #expect(await enrollment.value == .unavailable)
        #expect((await journal.snapshot()).1 == nil)
        #expect(await catalog.count() == 0)

        let restarted = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)
        guard case .ready = await restarted.enroll() else {
            Issue.record("Enrollment must resume after an unsent intent was aborted")
            return
        }
        #expect(await catalog.count() == 1)
    }

    @Test func preparedIntentCanBeRecoveredAfterCrashWithoutRemoteCreate() async throws {
        let catalog = Catalog()
        let journal = Journal()
        #expect(try await journal.beginCreateIfAbsent(incarnation: "prepared"))
        let restarted = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)

        #expect(await restarted.discover() == .ambiguous)
        #expect(await restarted.recoverPreparedEnrollment() == .enrollmentRequired)
        #expect((await journal.snapshot()).1 == nil)
        guard case .ready = await restarted.enroll() else {
            Issue.record("Explicit recovery must allow one new enrollment")
            return
        }
        #expect(await catalog.count() == 1)
    }

    @Test func preparedRecoveryCannotClearPossibleRemoteCreate() async throws {
        let journal = Journal()
        #expect(try await journal.beginCreateIfAbsent(incarnation: "dispatched"))
        #expect(
            try await journal.markCreateDispatchAttempted(
                location: .computer, incarnation: "dispatched"))
        let coordinator = DeviceRootEnrollmentCoordinator(backend: Catalog(), journal: journal)

        #expect(await coordinator.recoverPreparedEnrollment() == .ambiguous)
        #expect((await journal.snapshot()).1?.incarnation == "dispatched")
    }

    @Test func knownFallbackPreparationFailureLeavesNoRemoteIntent() async {
        let catalog = Catalog()
        await catalog.failNextFallbackPreparation()
        let journal = Journal()
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)

        #expect(await coordinator.enrollFallback() == .unavailable)
        #expect((await journal.snapshot()).1 == nil)
        #expect(await catalog.fallbackCount() == 0)

        await catalog.allowFallbackPreparation()
        let restarted = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)
        guard case .ready = await restarted.enrollFallback() else {
            Issue.record("A proven unsent fallback create must allow a later explicit retry")
            return
        }
        #expect(await catalog.fallbackCount() == 1)
    }

    @Test func cancellationOfStalledInventoryAllowsAnotherDiscovery() async {
        let catalog = Catalog()
        await catalog.pauseInventoryOnce()
        await catalog.releaseInventoryOnCancellation()
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: Journal())
        let discovery = Task { await coordinator.discover() }
        await catalog.waitForPausedInventory()

        discovery.cancel()
        #expect(await discovery.value == .unavailable)
        #expect(await coordinator.discover() == .enrollmentRequired)
    }

    @Test func aSecondCoordinatorCannotAdoptAnUnresolvedCreate() async {
        let catalog = Catalog()
        await catalog.pauseInventoryOnce()
        await catalog.setLostClaimResponse()
        let journal = Journal()
        let discoverer = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)
        let discovery = Task { await discoverer.discover() }
        await catalog.waitForPausedInventory()

        let enrolling = DeviceRootEnrollmentCoordinator(
            backend: catalog, journal: journal, makeIncarnation: { "first" })
        #expect(await enrolling.enroll() == .ambiguous)
        await catalog.releaseInventory()
        #expect(await discovery.value == .ambiguous)
        #expect((await journal.snapshot()).0 == nil)
        #expect((await journal.snapshot()).1 != nil)
    }

    @Test func discoveryNeverCreatesAnEmptyRoot() async {
        let catalog = Catalog()
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: Journal())

        #expect(await coordinator.discover() == .enrollmentRequired)
        #expect(await catalog.count() == 0)
    }

    @Test func explicitFallbackEnrollmentUsesMyFilesAndPersistsItsLocation() async {
        let catalog = Catalog()
        let journal = Journal()
        let coordinator = DeviceRootEnrollmentCoordinator(
            backend: catalog, journal: journal, makeIncarnation: { "fallback" })

        let expected = DeviceRootIdentity(
            deviceUID: "my-files", rootFolderUID: "fallback-folder",
            incarnation: "fallback", location: .myFiles)
        #expect(await coordinator.enrollFallback() == .ready(expected))
        #expect((await journal.snapshot()).0 == expected)
        #expect((await journal.snapshot()).1 == nil)
        #expect(await catalog.fallbackCount() == 1)
        #expect(await catalog.count() == 0)
    }

    @Test func explicitFallbackWorksWhenComputerEnumerationIsUnavailable() async {
        let catalog = Catalog()
        await catalog.setComputerUnavailable()
        let coordinator = DeviceRootEnrollmentCoordinator(
            backend: catalog, journal: Journal(), makeIncarnation: { "fallback" })
        let expected = DeviceRootIdentity(
            deviceUID: "my-files", rootFolderUID: "fallback-folder",
            incarnation: "fallback", location: .myFiles)

        #expect(await coordinator.enrollFallback() == .ready(expected))
        #expect(await catalog.fallbackCount() == 1)
        #expect(await catalog.count() == 0)
    }

    @Test func fallbackDiscoveryDoesNotChooseBetweenTwoVerifiedLocations() async {
        let fallback = DeviceRootIdentity(
            deviceUID: "my-files", rootFolderUID: "fallback-folder",
            incarnation: "fallback", location: .myFiles)
        let journal = Journal()
        let coordinator = DeviceRootEnrollmentCoordinator(
            backend: Catalog(candidates: [rootA, fallback]), journal: journal)

        #expect(await coordinator.discoverFallback() == .ambiguous)
        #expect((await journal.snapshot()).0 == nil)
    }

    @Test func fallbackEnrollmentDoesNotCreateBesideExistingComputerRoot() async {
        let catalog = Catalog(candidates: [rootA])
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: Journal())

        #expect(await coordinator.enrollFallback() == .ready(rootA))
        #expect(await catalog.fallbackCount() == 0)
    }

    @Test func lostFallbackCreateResponseNeverCreatesASecondFolder() async {
        let catalog = Catalog()
        await catalog.setLostResponse()
        let journal = Journal()
        let first = DeviceRootEnrollmentCoordinator(
            backend: catalog, journal: journal, makeIncarnation: { "fallback" })

        #expect(await first.enrollFallback() == .ambiguous)
        #expect((await journal.snapshot()).1?.location == .myFiles)
        let restarted = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)
        #expect(await restarted.enrollFallback() == .ambiguous)
        #expect(await catalog.fallbackCount() == 1)
        #expect(await catalog.count() == 0)
    }

    @Test func explicitEnrollmentPersistsIntentBeforeCreateAndThenSelectsRoot() async {
        let catalog = Catalog()
        let journal = Journal()
        await catalog.setJournal(journal)
        let coordinator = DeviceRootEnrollmentCoordinator(
            backend: catalog, journal: journal, makeIncarnation: { "first" })

        #expect(await coordinator.enroll() == .ready(rootA))
        let state = await journal.snapshot()
        #expect(state.0 == rootA)
        #expect(state.1 == nil)
        #expect(state.2 == 1)
        #expect(await catalog.count() == 1)
        #expect(await catalog.sawIntent())
        #expect(await catalog.sawDeviceCheckpoint())
    }

    @Test func lostCreateResponseStaysAmbiguousAcrossRestartWithoutRetry() async {
        let catalog = Catalog()
        await catalog.setLostResponse()
        let journal = Journal()
        let first = DeviceRootEnrollmentCoordinator(
            backend: catalog, journal: journal, makeIncarnation: { "first" })

        #expect(await first.enroll() == .ambiguous)
        let restarted = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)
        #expect(await restarted.discover() == .ambiguous)
        #expect(await restarted.enroll() == .ambiguous)
        #expect(await catalog.count() == 1)
    }

    @Test func explicitRecoveryAdoptsOnlyTheSingleVerifiedCreatedRoot() async {
        let catalog = Catalog()
        await catalog.setLostClaimResponse()
        let journal = Journal()
        await catalog.setJournal(journal)
        let interrupted = DeviceRootEnrollmentCoordinator(
            backend: catalog, journal: journal, makeIncarnation: { "first" })
        #expect(await interrupted.enroll() == .ambiguous)
        #expect((await journal.snapshot()).1?.createdDevice == deviceA)

        let restarted = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)
        #expect(await restarted.recoverCreatedRoot(rootA) == .ready(rootA))
        #expect(await restarted.discover() == .ready(rootA))
        #expect(await catalog.count() == 1)
    }

    @Test func explicitRecoveryRejectsASecondCandidate() async {
        let catalog = Catalog()
        await catalog.setLostResponse()
        let journal = Journal()
        let interrupted = DeviceRootEnrollmentCoordinator(
            backend: catalog, journal: journal, makeIncarnation: { "first" })
        #expect(await interrupted.enroll() == .ambiguous)
        await catalog.addUnclaimed(deviceB)

        let restarted = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)
        #expect(await restarted.recoverUnclaimedDevice(deviceA) == .ambiguous)
        #expect((await journal.snapshot()).0 == nil)
    }

    @Test func knownDeviceCheckpointResumesClaimAfterInterruption() async {
        let catalog = Catalog()
        await catalog.setFailBeforeClaim()
        let journal = Journal()
        await catalog.setJournal(journal)
        let interrupted = DeviceRootEnrollmentCoordinator(
            backend: catalog, journal: journal, makeIncarnation: { "first" })
        #expect(await interrupted.enroll() == .ambiguous)
        #expect((await journal.snapshot()).1?.createdDevice == deviceA)
        #expect(await catalog.sawDeviceCheckpoint())

        await catalog.allowClaim()
        let restarted = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)
        #expect(await restarted.recoverUnclaimedDevice(deviceA) == .ready(rootA))
        #expect(await catalog.count() == 1)
    }

    @Test func journaledDeviceRecoversAfterRenameBeforeClaim() async {
        let catalog = Catalog()
        await catalog.setFailBeforeClaim()
        let journal = Journal()
        let interrupted = DeviceRootEnrollmentCoordinator(
            backend: catalog, journal: journal, makeIncarnation: { "first" })
        #expect(await interrupted.enroll() == .ambiguous)

        await catalog.renameUnclaimed(deviceA)
        await catalog.allowClaim()
        let restarted = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)
        #expect(await restarted.recoverUnclaimedDevice(deviceA) == .ready(rootA))
        #expect(await catalog.count() == 1)
    }

    @Test func unknownCreateResponseNeedsExplicitUnclaimedDeviceRecovery() async {
        let catalog = Catalog()
        await catalog.setLostResponse()
        let journal = Journal()
        let interrupted = DeviceRootEnrollmentCoordinator(
            backend: catalog, journal: journal, makeIncarnation: { "first" })
        #expect(await interrupted.enroll() == .ambiguous)
        #expect((await journal.snapshot()).1?.createdDevice == nil)
        #expect(await interrupted.discover() == .ambiguous)
        #expect(await interrupted.recoverUnclaimedDevice(deviceA) == .ready(rootA))
        #expect(await catalog.count() == 1)
    }

    @Test func duplicateOrUnverifiedCandidatesNeverBecomeWritable() async {
        let duplicates = Catalog(candidates: [rootA, rootB])
        let first = DeviceRootEnrollmentCoordinator(backend: duplicates, journal: Journal())
        #expect(await first.discover() == .ambiguous)
        #expect(await first.enroll() == .ambiguous)
        #expect(await duplicates.count() == 0)

        let unreadable = Catalog(candidates: [rootA])
        await unreadable.setUnreadableClaim()
        let second = DeviceRootEnrollmentCoordinator(backend: unreadable, journal: Journal())
        #expect(await second.discover() == .ambiguous)
    }

    @Test func anUnclaimedDeviceBlocksAnotherEnrollment() async {
        let catalog = Catalog()
        await catalog.addUnclaimed(deviceA)
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: Journal())

        #expect(await coordinator.discover() == .ambiguous)
        #expect(await coordinator.enroll() == .ambiguous)
        #expect(await catalog.count() == 0)
    }

    @Test func incompleteInventoryDoesNotAuthorizeEnrollment() async {
        let catalog = Catalog()
        await catalog.setIncomplete()
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: Journal())

        #expect(await coordinator.enroll() == .unavailable)
        #expect(await catalog.count() == 0)
    }

    @Test func savedRootMissingFromInventoryDoesNotSwitchLocations() async throws {
        let journal = Journal()
        try await journal.select(rootA)
        let coordinator = DeviceRootEnrollmentCoordinator(backend: Catalog(), journal: journal)

        #expect(await coordinator.discover() == .unavailable)
    }

    @Test func fallbackCandidateCannotReplaceAMissingSelectedComputer() async throws {
        let journal = Journal()
        try await journal.select(rootA)
        let fallback = DeviceRootIdentity(
            deviceUID: "my-files", rootFolderUID: "fallback-folder",
            incarnation: "fallback", location: .myFiles)
        let coordinator = DeviceRootEnrollmentCoordinator(
            backend: Catalog(candidates: [fallback]), journal: journal)

        #expect(await coordinator.discover() == .ambiguous)
        #expect((await journal.snapshot()).0 == rootA)
    }

    @Test func selectedFallbackRemainsReadableWhenComputerEnumerationFails() async throws {
        let fallback = DeviceRootIdentity(
            deviceUID: "my-files", rootFolderUID: "fallback-folder",
            incarnation: "fallback", location: .myFiles)
        let journal = Journal()
        try await journal.select(fallback)
        let catalog = Catalog(candidates: [fallback])
        await catalog.setComputerUnavailable()
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)

        #expect(await coordinator.discover() == .ready(fallback))
    }

    @Test func selectedFallbackRejectsLaterComputerRoot() async throws {
        let fallback = DeviceRootIdentity(
            deviceUID: "my-files", rootFolderUID: "fallback-folder",
            incarnation: "fallback", location: .myFiles)
        let journal = Journal()
        try await journal.select(fallback)
        let coordinator = DeviceRootEnrollmentCoordinator(
            backend: Catalog(candidates: [fallback, rootA]), journal: journal)

        #expect(await coordinator.discover() == .ambiguous)
        #expect((await journal.snapshot()).0 == fallback)
    }

    @Test func selectedFallbackRejectsLaterUnclaimedComputer() async throws {
        let fallback = DeviceRootIdentity(
            deviceUID: "my-files", rootFolderUID: "fallback-folder",
            incarnation: "fallback", location: .myFiles)
        let journal = Journal()
        try await journal.select(fallback)
        let catalog = Catalog(candidates: [fallback])
        await catalog.addUnclaimed(deviceA)
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)

        #expect(await coordinator.discover() == .ambiguous)
    }

    @Test func pendingFallbackSelectionDoesNotSettleBesideComputerRoot() async throws {
        let fallback = DeviceRootIdentity(
            deviceUID: "my-files", rootFolderUID: "fallback-folder",
            incarnation: "fallback", location: .myFiles)
        let journal = Journal()
        #expect(try await journal.beginCreateIfAbsent(location: .myFiles, incarnation: "fallback"))
        try await journal.select(fallback)
        let coordinator = DeviceRootEnrollmentCoordinator(
            backend: Catalog(candidates: [fallback, rootA]), journal: journal)

        #expect(await coordinator.discover() == .ambiguous)
        #expect((await journal.snapshot()).1 != nil)
    }

    @Test func anotherDeviceExplicitlyJoinsVerifiedFallbackWhenComputerIsUnavailable() async {
        let fallback = DeviceRootIdentity(
            deviceUID: "my-files", rootFolderUID: "fallback-folder",
            incarnation: "fallback", location: .myFiles)
        let catalog = Catalog(candidates: [fallback])
        await catalog.setComputerUnavailable()
        let journal = Journal()
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)

        #expect(await coordinator.discover() == .unavailable)
        #expect(await coordinator.discoverFallback() == .ready(fallback))
        #expect((await journal.snapshot()).0 == fallback)
        #expect(await catalog.count() == 0)
        #expect(await catalog.fallbackCount() == 0)
    }

    @Test func fallbackRecoveryDoesNotSelectBesideComputerRoot() async throws {
        let fallback = DeviceRootIdentity(
            deviceUID: "my-files", rootFolderUID: "fallback-folder",
            incarnation: "fallback", location: .myFiles)
        let journal = Journal()
        #expect(
            try await journal.beginCreateIfAbsent(
                location: .myFiles, incarnation: "fallback"))
        let coordinator = DeviceRootEnrollmentCoordinator(
            backend: Catalog(candidates: [rootA, fallback]), journal: journal)

        #expect(await coordinator.recoverCreatedRoot(fallback) == .ambiguous)
        #expect((await journal.snapshot()).0 == nil)
    }

    @Test func unclaimedFallbackRecoveryDoesNotClaimBesideComputerRoot() async throws {
        let fallback = DeviceRootUnclaimedDevice(
            deviceUID: "my-files", rootFolderUID: "fallback-folder", location: .myFiles)
        let catalog = Catalog(candidates: [rootA])
        await catalog.addUnclaimed(fallback)
        let journal = Journal()
        #expect(
            try await journal.beginCreateIfAbsent(
                location: .myFiles, incarnation: "fallback"))
        let coordinator = DeviceRootEnrollmentCoordinator(backend: catalog, journal: journal)

        #expect(await coordinator.recoverUnclaimedDevice(fallback) == .ambiguous)
        #expect((await journal.snapshot()).0 == nil)
    }

    @Test func restartAfterSelectionSettlesCreateIntent() async throws {
        let journal = Journal()
        #expect(try await journal.beginCreateIfAbsent(incarnation: "first"))
        try await journal.recordCreatedDevice(deviceA)
        try await journal.select(rootA)
        let coordinator = DeviceRootEnrollmentCoordinator(
            backend: Catalog(candidates: [rootA]), journal: journal)

        #expect(await coordinator.discover() == .ready(rootA))
        #expect((await journal.snapshot()).1 == nil)
    }
}

private extension Catalog {
    func setJournal(_ journal: Journal) { journalAtCreate = journal }
    func setLostResponse() { loseCreateResponse = true }
    func setLostClaimResponse() { loseClaimResponse = true }
    func setFailBeforeClaim() { failBeforeClaim = true }
    func allowClaim() { failBeforeClaim = false }
    func setUnreadableClaim() { unreadableClaim = true }
    func setIncomplete() { complete = false }
    func setComputerUnavailable() { computerUnavailable = true }
    func addCandidate(_ candidate: DeviceRootIdentity) { candidates.append(candidate) }
    func addUnclaimed(_ candidate: DeviceRootUnclaimedDevice) { unclaimed.append(candidate) }
}
