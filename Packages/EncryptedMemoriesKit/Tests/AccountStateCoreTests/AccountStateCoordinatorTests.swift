import DeviceRootCore
import Foundation
import PhotosCore
import Testing

@testable import AccountStateCore

@Suite("Account state coordinator")
struct AccountStateCoordinatorTests {
    @Test func refreshMergesAndPublishesLocalChanges() async throws {
        let harness = try Harness.published()
        var local = try documentHiding([photoA])
        try local.setHidden(photoB, true, at: stateDate(4_000), deviceID: "iphone", nonce: 2)
        harness.local.set(
            AccountStateLocalRecord(
                binding: testBinding, document: try local.encoded(), lastSealed: nil, published: true,
                hasUnpublishedChanges: true))

        let status = await harness.coordinator().refresh()

        #expect(status.document?.hiddenPhotos == [photoA, photoB])
        #expect(status.isReady)
        #expect(harness.store.remoteDocument?.hiddenPhotos == [photoA, photoB])
        #expect(harness.local.record?.hasUnpublishedChanges == false)
    }

    @Test func updatePersistsTheChangeLocallyBeforeTheWrite() async throws {
        let harness = try Harness.published()
        harness.store.addWriteFaults(.fail(DeviceRootOperationError.unavailable))

        let status = try await harness.coordinator().update(hiding(photoB))

        #expect(status.isUnavailable)
        #expect(harness.store.appliedWrites == 0)
        #expect(harness.local.document?.hiddenPhotos == [photoA, photoB])
        #expect(harness.local.record?.hasUnpublishedChanges == true)
    }

    @Test func criticalWritesStayClosedWithoutProof() async throws {
        let harness = try Harness.published(writesEnabled: false)
        let coordinator = harness.coordinator()

        await #expect(throws: AccountStateWritesUnsupportedError.self) {
            try await coordinator.update(hiding(photoB))
        }
        await #expect(throws: AccountStateWritesUnsupportedError.self) { try await coordinator.initialize() }
        await #expect(throws: AccountStateWritesUnsupportedError.self) {
            try await coordinator.resetFromLocalCopy()
        }
        #expect(harness.local.saves == 0)
        #expect(harness.store.writeAttempts == 0)
        #expect(await coordinator.refresh().isReady)
        #expect(harness.store.writeAttempts == 0)

        // A restore changes the server too, so a trashed state stays trashed.
        harness.store.trash()
        #expect(await coordinator.refresh().isUnavailable)
        #expect(harness.store.restores == 0)
        #expect(harness.store.isTrashed)
    }

    @Test func refreshWithoutWritePermissionKeepsLocalChangesPending() async throws {
        let harness = try Harness.published(writesEnabled: false)
        let local = try documentHiding([photoA, photoB])
        harness.local.set(
            AccountStateLocalRecord(
                binding: testBinding, document: try local.encoded(), lastSealed: nil, published: true,
                hasUnpublishedChanges: true))

        let status = await harness.coordinator().refresh()

        #expect(status.document?.hiddenPhotos == [photoA, photoB])
        #expect(harness.store.writeAttempts == 0)
        #expect(harness.local.record?.hasUnpublishedChanges == true)
    }

    @Test func onlyTheFirstSetupCreatesTheState() async throws {
        let harness = Harness()
        #expect(await harness.coordinator().refresh() == .closed(.notInitialized))
        #expect(try await harness.coordinator().update(hiding(photoB)) == .closed(.notInitialized))
        #expect(harness.store.writeAttempts == 0)

        let status = try await harness.coordinator().initialize()

        #expect(status.isReady)
        #expect(harness.store.exists)
        #expect(harness.local.record?.published == true)
        #expect(harness.sealer.keysUsed == ["new1"])
    }

    @Test func secondDeviceJoinsInsteadOfCreating() async throws {
        let first = Harness()
        _ = try await first.coordinator().initialize()
        _ = try await first.coordinator().update(hiding(photoA))
        let second = Harness(local: FakeLocalStore())
        second.store.seedRaw(try #require(first.store.remoteDocument.map { first.sealer.sealDirect($0, key: "new1") }))

        let status = try await second.coordinator().initialize()

        #expect(status.document?.hiddenPhotos == [photoA])
        #expect(second.store.writeAttempts == 0)
    }

    @Test func aLostStateIsNeverRecreatedAutomatically() async throws {
        let harness = try Harness.published()
        harness.store.deletePermanently()
        let coordinator = harness.coordinator()

        #expect(await coordinator.refresh() == .closed(.missing))
        #expect(try await coordinator.update(hiding(photoB)) == .closed(.missing))
        #expect(try await coordinator.initialize() == .closed(.missing))
        #expect(!harness.store.exists)
        #expect(harness.local.document?.hiddenPhotos == [photoA])
    }

    @Test func ownerResetRecreatesFromTheLocalCopyWithSharingOff() async throws {
        let harness = try Harness.published()
        var local = try documentHiding([photoA])
        try local.setValue(true, for: .sharedLibraryEnabled, at: stateDate(3_000), deviceID: "mac", nonce: 1)
        harness.local.set(
            AccountStateLocalRecord(
                binding: testBinding, document: try local.encoded(),
                lastSealed: harness.sealer.sealDirect(local, key: "old"),
                published: true, hasUnpublishedChanges: false))
        harness.store.deletePermanently()

        let status = try await harness.coordinator().resetFromLocalCopy()

        #expect(status.isReady)
        let remote = try #require(harness.store.remoteDocument)
        #expect(remote.hiddenPhotos == [photoA])
        #expect(remote.value(for: .sharedLibraryEnabled) == false)
        #expect(harness.sealer.keysUsed == ["old"])
    }

    @Test func concurrentUpdatesOnOneCoordinatorBothSurvive() async throws {
        let harness = try Harness.published()
        let coordinator = harness.coordinator()

        async let first = coordinator.update(hiding(photoB, at: 5_000))
        async let second = coordinator.update(hiding(photoC, at: 5_001))
        _ = try await (first, second)

        #expect(harness.store.remoteDocument?.hiddenPhotos == [photoA, photoB, photoC])
        #expect(harness.local.document?.hiddenPhotos == [photoA, photoB, photoC])
    }

    @Test func everyWriteReusesTheKeyOfTheFileItRead() async throws {
        let harness = try Harness.published()
        _ = try await harness.coordinator().update(hiding(photoB))
        _ = try await harness.coordinator().update(hiding(photoC, at: 6_000))
        #expect(harness.sealer.keysUsed == ["k0", "k0"])
    }

    @Test func aDamagedLocalCopyClosesInsteadOfBeingOverwritten() async throws {
        let harness = try Harness.published()
        harness.local.set(
            AccountStateLocalRecord(
                binding: testBinding, document: Data(#"{"format":1,"hidden":7}"#.utf8), lastSealed: nil,
                published: true,
                hasUnpublishedChanges: true))

        #expect(await harness.coordinator().refresh() == .closed(.localCopyUnavailable))
        #expect(harness.store.writeAttempts == 0)
    }

    @Test func aLocalCopyOfAnotherBindingIsNeverMerged() async throws {
        let harness = try Harness.published()
        let foreign = AccountStateLocalRecord(
            binding: AccountStateBinding(accountID: "other-account", rootIncarnation: "incarnation", stateID: "state"),
            document: try documentHiding([photoB]).encoded(), lastSealed: nil, published: true,
            hasUnpublishedChanges: true)
        harness.local.set(foreign)
        let coordinator = harness.coordinator()

        #expect(await coordinator.refresh() == .closed(.foreignLocalCopy))
        #expect(try await coordinator.update(hiding(photoC)) == .closed(.foreignLocalCopy))
        #expect(try await coordinator.initialize() == .closed(.foreignLocalCopy))
        #expect(harness.store.writeAttempts == 0)
        #expect(harness.local.record == foreign)
    }

    @Test func aMovedLocalCopyIsNeverWrittenToTheOldLocation() async throws {
        let harness = Harness()
        var moved = AccountStateDocument()
        try moved.markMoved(to: "new-location", at: stateDate(1_000), deviceID: "mac", nonce: 1)
        harness.local.set(
            AccountStateLocalRecord(
                binding: testBinding, document: try moved.encoded(), lastSealed: nil, published: false,
                hasUnpublishedChanges: true))

        #expect(try await harness.coordinator().initialize() == .moved(moved))
        #expect(harness.store.writeAttempts == 0)
    }

    @Test func firstSetupFromAnEarlierLocalCopyTurnsSharingOff() async throws {
        // An earlier create arrived, its settlement was lost, and the state vanished before a refresh healed it.
        let harness = Harness()
        var local = try documentHiding([photoA])
        try local.setValue(true, for: .sharedLibraryEnabled, at: stateDate(3_000), deviceID: "mac", nonce: 1)
        harness.local.set(
            AccountStateLocalRecord(
                binding: testBinding, document: try local.encoded(), lastSealed: nil, published: false,
                hasUnpublishedChanges: true))

        #expect(try await harness.coordinator().initialize().isReady)
        let remote = try #require(harness.store.remoteDocument)
        #expect(remote.hiddenPhotos == [photoA])
        #expect(remote.value(for: .sharedLibraryEnabled) == false)
    }

    @Test func aCancelledCallerCausesNoSideEffect() async throws {
        let harness = try Harness.published()
        harness.store.trash()
        let coordinator = harness.coordinator()

        let status = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.update(hiding(photoB))
        }.value

        #expect(status.isUnavailable)
        #expect(harness.store.reads == 0)
        #expect(harness.store.restores == 0)
        #expect(harness.store.writeAttempts == 0)
        #expect(harness.local.saves == 0)
    }

    @Test func aConflictRetryStopsWhenItsMergeCannotBeSaved() async throws {
        let harness = try Harness.published()
        harness.store.addWriteFaults(.competingWrite(try documentHiding([photoA, photoC])))
        // The copy before the write succeeds; the copy of the merge with the other writer fails.
        harness.local.failSavesAfter = 1

        let status = try await harness.coordinator().update(hiding(photoB))

        #expect(status == .closed(.localCopyUnavailable))
        #expect(harness.store.writeAttempts == 1, "no retry without a durable copy of the merge")
    }

    @Test func aResetThatFailsBeforeItIsSentCanRunAgain() async throws {
        let harness = try Harness.published()
        harness.store.deletePermanently()
        harness.store.addWriteFaults(.fail(DeviceRootOperationError.unavailable))
        let coordinator = harness.coordinator()

        #expect(try await coordinator.resetFromLocalCopy().isUnavailable)
        #expect(harness.local.record?.published == true)
        #expect(await coordinator.refresh() == .closed(.missing), "the state still counts as lost, not as new")
        #expect(try await coordinator.resetFromLocalCopy().isReady)
    }

    @Test func aFenceChangeDuringTheLocalSaveIgnoresTheResult() async throws {
        let harness = try Harness.published()
        let fence = harness.fence
        harness.local.onSave = { fence.isCurrent = false }

        #expect(await harness.coordinator().refresh() == .closed(.fenced))
    }

    @Test func aCancellationDuringSealingSendsNothing() async throws {
        let harness = try Harness.published()
        harness.sealer.onSeal = { withUnsafeCurrentTask { $0?.cancel() } }
        let coordinator = harness.coordinator()

        let status = try await Task { try await coordinator.update(hiding(photoB)) }.value

        #expect(status.isUnavailable)
        #expect(harness.store.writeAttempts == 0)
    }

    @Test func aDamagedStateInTheTrashStaysThere() async throws {
        let harness = Harness()
        harness.store.seedRaw(Data("S1|account|incarnation|state|k0|{\"format\":1,\"hidden\":7}".utf8))
        harness.store.trash()

        #expect(await harness.coordinator().refresh() == .closed(.damaged))
        #expect(harness.store.restores == 0)
        #expect(harness.store.isTrashed)
    }
}
