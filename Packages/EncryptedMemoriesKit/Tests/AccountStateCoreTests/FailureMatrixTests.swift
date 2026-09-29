import DeviceRootCore
import Foundation
import PhotosCore
import Testing

@testable import AccountStateCore

/// The account state cells of the failure matrix in #102: R reads the state, W writes it with compare-and-swap,
/// and T restores it from the trash. Each test carries its cell name, for example `W_F01`. Each cell asserts the next
/// permitted action (status), the server effect, and the local copy, which is the write journal.
@Suite("Failure matrix: account state")
struct FailureMatrixTests {
    private let targetModel = AccountSettingKey<String>(
        name: "smartSearch.targetModel", encode: { .string($0) }, decode: { $0.stringValue })

    // MARK: - Assertions

    private func expectServerUnchanged(_ harness: Harness, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(harness.store.appliedWrites == 0, sourceLocation: sourceLocation)
        #expect(harness.store.remoteDocument?.hiddenPhotos == [photoA], sourceLocation: sourceLocation)
    }

    private func expectIntentKept(_ harness: Harness, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(harness.local.document?.hiddenPhotos == [photoA, photoB], sourceLocation: sourceLocation)
        #expect(harness.local.record?.hasUnpublishedChanges == true, sourceLocation: sourceLocation)
    }

    private func expectLocalUnchanged(_ harness: Harness, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(harness.local.document?.hiddenPhotos == [photoA], sourceLocation: sourceLocation)
        #expect(harness.local.record?.hasUnpublishedChanges == false, sourceLocation: sourceLocation)
    }

    private func trashedHarness() throws -> Harness {
        let harness = try Harness.published()
        harness.store.trash()
        return harness
    }

    // MARK: - F01 network lost before the request

    @Test("R_F01") func rF01() async throws {
        let harness = try Harness.published()
        harness.store.addReadFaults(.fail(DeviceRootOperationError.unavailable))
        let status = await harness.coordinator().refresh()
        #expect(status == .unavailable(lastKnown: try documentHiding([photoA])))
        expectServerUnchanged(harness)
        #expect(harness.local.saves == 0)
    }

    @Test("W_F01") func wF01() async throws {
        let harness = try Harness.published()
        harness.store.addWriteFaults(.fail(DeviceRootOperationError.notDispatched))
        #expect(try await harness.coordinator().update(hiding(photoB)).isUnavailable)
        expectServerUnchanged(harness)
        expectIntentKept(harness)

        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.remoteDocument?.hiddenPhotos == [photoA, photoB])
    }

    @Test("T_F01") func tF01() async throws {
        let harness = try trashedHarness()
        harness.store.addRestoreFaults(.fail(DeviceRootOperationError.unavailable))
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(harness.store.isTrashed)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F02 network lost mid-request, the request did not arrive

    @Test("R_F02") func rF02() async throws {
        let harness = try Harness.published()
        harness.store.addReadFaults(.fail(DeviceRootOperationError.unknownOutcome))
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(await harness.coordinator().refresh().isReady)
        expectServerUnchanged(harness)
    }

    @Test("W_F02") func wF02() async throws {
        let harness = try Harness.published()
        harness.store.addWriteFaults(.fail(DeviceRootOperationError.unknownOutcome))
        #expect(try await harness.coordinator().update(hiding(photoB)).isReady)
        #expect(harness.store.writeAttempts == 2)
        #expect(harness.store.appliedWrites == 1)
        #expect(harness.store.remoteDocument?.hiddenPhotos == [photoA, photoB])
        #expect(harness.local.record?.hasUnpublishedChanges == false)
    }

    @Test("T_F02") func tF02() async throws {
        let harness = try trashedHarness()
        harness.store.addRestoreFaults(.fail(DeviceRootOperationError.unknownOutcome))
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(harness.store.isTrashed)
        #expect(await harness.coordinator().refresh().isReady)
        #expect(!harness.store.isTrashed)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F03 response lost after success

    @Test("R_F03") func rF03() async throws {
        let harness = try Harness.published()
        harness.store.addReadFaults(.applyThenFail(DeviceRootOperationError.unknownOutcome))
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.reads == 2)
        expectServerUnchanged(harness)
    }

    @Test("W_F03") func wF03() async throws {
        let harness = try Harness.published()
        harness.store.addWriteFaults(.applyThenFail(DeviceRootOperationError.unknownOutcome))
        let status = try await harness.coordinator().update(hiding(photoB))
        #expect(status.isReady)
        #expect(harness.store.writeAttempts == 1)
        #expect(harness.store.remoteDocument?.hiddenPhotos == [photoA, photoB])
        #expect(harness.local.record?.hasUnpublishedChanges == false)
    }

    @Test("T_F03") func tF03() async throws {
        let harness = try trashedHarness()
        harness.store.addRestoreFaults(.applyThenFail(DeviceRootOperationError.unknownOutcome))
        #expect(await harness.coordinator().refresh().isReady)
        #expect(!harness.store.isTrashed)
        #expect(harness.store.restores == 1)
    }

    // MARK: - F04 endpoint permanently unavailable

    @Test("R_F04") func rF04() async throws {
        let harness = try Harness.published()
        let unavailable = StoreFault.fail(DeviceRootOperationError.unavailable)
        harness.store.addReadFaults(unavailable, unavailable, unavailable)
        for _ in 0..<3 { #expect(await harness.coordinator().refresh().isUnavailable) }
        expectServerUnchanged(harness)
        expectLocalUnchanged(harness)
    }

    @Test("W_F04") func wF04() async throws {
        let harness = try Harness.published()
        let unavailable = StoreFault.fail(DeviceRootOperationError.unavailable)
        harness.store.addWriteFaults(unavailable, unavailable)
        #expect(try await harness.coordinator().update(hiding(photoB)).isUnavailable)
        #expect(await harness.coordinator().refresh().isUnavailable)
        expectServerUnchanged(harness)
        expectIntentKept(harness)
    }

    @Test("T_F04") func tF04() async throws {
        let harness = try trashedHarness()
        let unavailable = StoreFault.fail(DeviceRootOperationError.unavailable)
        harness.store.addRestoreFaults(unavailable, unavailable)
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(harness.store.isTrashed)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F05 conditional conflict

    @Test("R_F05") func rF05() async throws {
        let harness = try Harness.published()
        harness.store.addReadFaults(.fail(DeviceRootOperationError.conflict))
        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.reads == 2)
    }

    @Test("W_F05") func wF05() async throws {
        let harness = try Harness.published()
        harness.store.addWriteFaults(.competingWrite(try documentHiding([photoA, photoC], device: "mac")))
        let status = try await harness.coordinator().update(hiding(photoB))
        #expect(status.isReady)
        #expect(harness.store.remoteDocument?.hiddenPhotos == [photoA, photoB, photoC])
        #expect(harness.store.writeAttempts == 2)
    }

    @Test("T_F05") func tF05() async throws {
        let harness = try trashedHarness()
        harness.store.addRestoreFaults(.applyThenFail(DeviceRootOperationError.conflict))
        #expect(await harness.coordinator().refresh().isReady)
        #expect(!harness.store.isTrashed)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F06 repeated conflicts or concurrent writers

    @Test("R_F06") func rF06() async throws {
        let harness = try Harness.published()
        let conflict = StoreFault.fail(DeviceRootOperationError.conflict)
        harness.store.addReadFaults(conflict, conflict, conflict)
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(harness.store.reads == 3)
        expectLocalUnchanged(harness)
    }

    @Test("W_F06") func wF06() async throws {
        let harness = try Harness.published(maximumAttempts: 3)
        for index in 0..<3 {
            harness.store.addWriteFaults(
                .competingWrite(try documentHiding([photoA, photoC], device: "mac", start: 2_000 + Int64(index))))
        }
        #expect(try await harness.coordinator().update(hiding(photoB)) == .closed(.contention))
        #expect(harness.store.writeAttempts == 3)
        #expect(harness.store.remoteDocument?.isHidden(photoB) == false)
        #expect(harness.local.document?.hiddenPhotos == [photoA, photoB, photoC])
        #expect(harness.local.record?.hasUnpublishedChanges == true)
    }

    @Test("T_F06") func tF06() async throws {
        let harness = try trashedHarness()
        harness.store.addRestoreFaults(.fail(DeviceRootOperationError.conflict))
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(harness.store.restores == 1)
        #expect(harness.store.isTrashed)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F07 throttled

    @Test("R_F07") func rF07() async throws {
        let harness = try Harness.published()
        harness.store.addReadFaults(.fail(DeviceRootOperationError.rateLimited))
        #expect(await harness.coordinator().refresh().isUnavailable)
        expectLocalUnchanged(harness)
    }

    @Test("W_F07") func wF07() async throws {
        let harness = try Harness.published()
        harness.store.addWriteFaults(.fail(DeviceRootOperationError.rateLimited))
        #expect(try await harness.coordinator().update(hiding(photoB)).isUnavailable)
        #expect(harness.store.writeAttempts == 1)
        expectServerUnchanged(harness)
        expectIntentKept(harness)
    }

    @Test("T_F07") func tF07() async throws {
        let harness = try trashedHarness()
        harness.store.addRestoreFaults(.fail(DeviceRootOperationError.rateLimited))
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(harness.store.isTrashed)
    }

    // MARK: - F08 server error, timeout, or unknown SDK error

    @Test("R_F08") func rF08() async throws {
        let harness = try Harness.published()
        harness.store.addReadFaults(.fail(TestFailure()))
        #expect(await harness.coordinator().refresh().isUnavailable)
        expectLocalUnchanged(harness)
    }

    @Test("W_F08") func wF08() async throws {
        let arrived = try Harness.published()
        arrived.store.addWriteFaults(.applyThenFail(TestFailure()))
        #expect(try await arrived.coordinator().update(hiding(photoB)).isReady)
        #expect(arrived.store.writeAttempts == 1)
        #expect(arrived.store.remoteDocument?.hiddenPhotos == [photoA, photoB])

        let lost = try Harness.published()
        lost.store.addWriteFaults(.fail(TestFailure()))
        #expect(try await lost.coordinator().update(hiding(photoB)).isReady)
        #expect(lost.store.writeAttempts == 2)
        #expect(lost.store.appliedWrites == 1)
        #expect(lost.store.reads == 2)
    }

    @Test("T_F08") func tF08() async throws {
        let harness = try trashedHarness()
        harness.store.addRestoreFaults(.fail(TestFailure()))
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(harness.store.isTrashed)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F09 quota exceeded mid-upload

    @Test("R_F09") func rF09() async throws {
        let harness = try Harness.published()
        harness.store.externalWrite(try documentHiding([photoA, photoC], device: "mac"))
        harness.local.set(
            AccountStateLocalRecord(
                binding: testBinding, document: try documentHiding([photoA, photoB]).encoded(), lastSealed: nil,
                published: true,
                hasUnpublishedChanges: true))
        harness.store.addWriteFaults(.fail(DeviceRootOperationError.quota))
        #expect(await harness.coordinator().refresh() == .closed(.quota))
        #expect(harness.local.document?.hiddenPhotos == [photoA, photoB, photoC])
        #expect(harness.local.record?.hasUnpublishedChanges == true)
    }

    @Test("W_F09") func wF09() async throws {
        let harness = try Harness.published()
        harness.store.addWriteFaults(.fail(DeviceRootOperationError.quota))
        #expect(try await harness.coordinator().update(hiding(photoB)) == .closed(.quota))
        expectServerUnchanged(harness)
        expectIntentKept(harness)
    }

    @Test("T_F09") func tF09() async throws {
        let harness = try trashedHarness()
        harness.store.addRestoreFaults(.fail(DeviceRootOperationError.quota))
        #expect(await harness.coordinator().refresh() == .closed(.quota))
        #expect(harness.store.isTrashed)
        expectLocalUnchanged(harness)
    }

    // MARK: - F10 storage nearly full or budget change mid-cycle

    @Test("R_F10") func rF10() async throws {
        // State reads have no budget: a full index budget or low storage never blocks them.
        let harness = try Harness.published()
        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.writeAttempts == 0)
    }

    @Test("W_F10") func wF10() async throws {
        // A critical write has no index budget; only the service quota can stop it, and then it closes at once.
        let harness = try Harness.published()
        harness.store.addWriteFaults(.fail(DeviceRootOperationError.quota))
        #expect(try await harness.coordinator().update(hiding(photoB)) == .closed(.quota))
        #expect(harness.store.writeAttempts == 1)
        expectIntentKept(harness)
    }

    @Test("T_F10") func tF10() async throws {
        // A restore takes no new storage and runs before any budget-limited work.
        let harness = try trashedHarness()
        harness.store.addWriteFaults(.fail(DeviceRootOperationError.quota))
        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.restores == 1)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F11 leftover draft or partial revision

    @Test("R_F11") func rF11() async throws {
        let harness = Harness()
        harness.store.seedRaw(harness.sealer.sealDirect(try documentHiding([photoA])), committed: false)
        #expect(await harness.coordinator().refresh() == .closed(.incomplete))
        #expect(harness.store.writeAttempts == 0)
    }

    @Test("W_F11") func wF11() async throws {
        // Another client's open draft rejects the write; the next attempt runs after a fresh read.
        let harness = try Harness.published()
        harness.store.addWriteFaults(.fail(DeviceRootOperationError.conflict))
        #expect(try await harness.coordinator().update(hiding(photoB)).isReady)
        #expect(harness.store.writeAttempts == 2)
        #expect(harness.store.appliedWrites == 1)
    }

    @Test("T_F11") func tF11() async throws {
        let harness = Harness()
        harness.store.seedRaw(harness.sealer.sealDirect(try documentHiding([photoA])), committed: false)
        harness.store.trash()
        #expect(await harness.coordinator().refresh() == .closed(.incomplete))
        #expect(harness.store.restores == 1)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F12 file trashed during the step

    @Test("R_F12") func rF12() async throws {
        let harness = try Harness.published()
        harness.store.addReadFaults(.trashFirst)
        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.restores == 1)
        #expect(!harness.store.isTrashed)
    }

    @Test("W_F12") func wF12() async throws {
        let harness = try Harness.published()
        harness.store.addWriteFaults(.trashFirst)
        #expect(try await harness.coordinator().update(hiding(photoB)).isReady)
        #expect(harness.store.restores == 1)
        #expect(!harness.store.isTrashed)
        #expect(harness.store.remoteDocument?.hiddenPhotos == [photoA, photoB])
    }

    @Test("T_F12") func tF12() async throws {
        let harness = try trashedHarness()
        harness.store.addReadFaults(.pass, .trashFirst)
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(harness.store.isTrashed)
        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.restores == 2)
    }

    // MARK: - F13 state or device removed for good

    @Test("R_F13") func rF13() async throws {
        let harness = try Harness.published()
        harness.store.deletePermanently()
        #expect(await harness.coordinator().refresh() == .closed(.missing))
        #expect(harness.store.writeAttempts == 0)
        expectLocalUnchanged(harness)
    }

    @Test("W_F13") func wF13() async throws {
        let harness = try Harness.published()
        harness.store.deletePermanently()
        #expect(try await harness.coordinator().update(hiding(photoB)) == .closed(.missing))
        #expect(!harness.store.exists)
        expectLocalUnchanged(harness)
    }

    @Test("T_F13") func tF13() async throws {
        let harness = try Harness.published()
        harness.store.deletePermanently()
        #expect(await harness.coordinator().refresh() == .closed(.missing))
        #expect(!harness.store.exists)

        #expect(try await harness.coordinator().resetFromLocalCopy().isReady)
        #expect(harness.store.remoteDocument?.hiddenPhotos == [photoA])
        #expect(harness.store.remoteDocument?.value(for: .sharedLibraryEnabled) == false)
    }

    // MARK: - F14 bad signature or failed download verification

    @Test("R_F14") func rF14() async throws {
        let harness = try Harness.published()
        harness.store.addReadFaults(.failedVerification)
        #expect(await harness.coordinator().refresh() == .closed(.verificationFailed))
        #expect(harness.store.writeAttempts == 0)
        expectLocalUnchanged(harness)
    }

    @Test("W_F14") func wF14() async throws {
        let harness = try Harness.published()
        harness.sealer.openOverride = .rejected(.badSignature)
        #expect(try await harness.coordinator().update(hiding(photoB)) == .closed(.rejected(.badSignature)))
        expectServerUnchanged(harness)
        expectLocalUnchanged(harness)
    }

    @Test("T_F14") func tF14() async throws {
        let harness = try trashedHarness()
        harness.store.addReadFaults(.pass, .failedVerification)
        #expect(await harness.coordinator().refresh() == .closed(.verificationFailed))
        #expect(harness.store.restores == 1)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F15 corrupt, truncated, or newer format

    @Test("R_F15") func rF15() async throws {
        let garbage = Harness()
        garbage.store.seedRaw(Data("truncated".utf8))
        #expect(await garbage.coordinator().refresh() == .closed(.rejected(.malformed)))

        let damaged = Harness()
        damaged.store.seedRaw(Data("S1|account|incarnation|state|k0|{\"format\":1,\"hidden\":7}".utf8))
        #expect(await damaged.coordinator().refresh() == .closed(.damaged))

        let newer = Harness()
        newer.store.seedRaw(Data("S2|account|incarnation|state|k0|opaque".utf8))
        #expect(await newer.coordinator().refresh() == .readOnly(format: 2))
        #expect(garbage.store.writeAttempts + damaged.store.writeAttempts + newer.store.writeAttempts == 0)
    }

    @Test("W_F15") func wF15() async throws {
        let harness = try Harness.published()
        let newerDocument = Data("S1|account|incarnation|state|k0|{\"format\":2,\"hidden\":\"new layout\"}".utf8)
        harness.store.seedRaw(newerDocument)
        #expect(try await harness.coordinator().update(hiding(photoB)) == .readOnly(format: 2))
        #expect(harness.store.writeAttempts == 0)
        expectLocalUnchanged(harness)
    }

    @Test("T_F15") func tF15() async throws {
        let harness = Harness()
        harness.store.seedRaw(Data("S2|account|incarnation|state|k0|opaque".utf8))
        harness.store.trash()
        #expect(await harness.coordinator().refresh() == .readOnly(format: 2))
        #expect(harness.store.restores == 1)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F16 wrong or rotated key

    @Test("R_F16") func rF16() async throws {
        let harness = try Harness.published()
        harness.sealer.openOverride = .rejected(.keyUnavailable)
        #expect(await harness.coordinator().refresh() == .closed(.rejected(.keyUnavailable)))
        expectLocalUnchanged(harness)
    }

    @Test("W_F16") func wF16() async throws {
        let harness = try Harness.published()
        harness.sealer.openOverride = .rejected(.keyUnavailable)
        #expect(try await harness.coordinator().update(hiding(photoB)) == .closed(.rejected(.keyUnavailable)))
        expectServerUnchanged(harness)
    }

    @Test("T_F16") func tF16() async throws {
        let harness = try trashedHarness()
        harness.sealer.openOverride = .rejected(.keyUnavailable)
        #expect(await harness.coordinator().refresh() == .closed(.rejected(.keyUnavailable)))
        #expect(harness.store.restores == 1)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F17 cloned device or clock skew

    @Test("R_F17") func rF17() async throws {
        // Stamps from a device whose clock runs far ahead merge like any other; the local clock decides nothing.
        let harness = try Harness.published()
        var future = try documentHiding([photoA])
        try future.setHidden(photoC, true, at: stateDate(4_000_000_000_000), deviceID: "mac", nonce: 1)
        harness.store.externalWrite(future)
        let status = await harness.coordinator().refresh()
        #expect(status.document?.hiddenPhotos == [photoA, photoC])
    }

    @Test("W_F17") func wF17() async throws {
        let harness = try Harness.published()
        var shownInFuture = try documentHiding([photoA])
        try shownInFuture.setHidden(photoA, false, at: stateDate(4_000_000_000_000), deviceID: "mac", nonce: 1)
        harness.store.externalWrite(shownInFuture)
        // A change made with a clock far behind still supersedes what it saw.
        let status = try await harness.coordinator().update(hiding(photoA, at: 5_000))
        #expect(status.document?.isHidden(photoA) == true)

        // A clone with the same device ID and local copy writes through compare-and-swap too; nothing is lost.
        let clone = Harness(local: FakeLocalStore(harness.local.record))
        clone.store.seedRaw(try #require(harness.store.remoteDocument.map { harness.sealer.sealDirect($0) }))
        _ = try await clone.coordinator().update(hiding(photoB))
        _ = try await clone.coordinator().update(hiding(photoC, at: 6_000))
        #expect(clone.store.remoteDocument?.hiddenPhotos == [photoA, photoB, photoC])
    }

    @Test("T_F17") func tF17() async throws {
        // The trash state comes from the server; the local clock plays no part in the restore decision.
        let harness = try trashedHarness()
        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.restores == 1)
    }

    // MARK: - F18 killed, suspended, or out of background time after a journal step

    @Test("R_F18") func rF18() async throws {
        let harness = try Harness.published()
        harness.store.addReadFaults(.fail(CancellationError()))
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.writeAttempts == 0)
    }

    @Test("W_F18") func wF18() async throws {
        // Stopped before the write: the restarted coordinator publishes the journaled change.
        let beforeWrite = try Harness.published()
        beforeWrite.store.addWriteFaults(.fail(CancellationError()))
        #expect(try await beforeWrite.coordinator().update(hiding(photoB)).isUnavailable)
        expectIntentKept(beforeWrite)
        #expect(await beforeWrite.coordinator().refresh().isReady)
        #expect(beforeWrite.store.remoteDocument?.hiddenPhotos == [photoA, photoB])

        // Stopped after the write arrived: the restart settles it without a second write.
        let afterWrite = try Harness.published()
        afterWrite.store.addWriteFaults(.applyThenFail(CancellationError()))
        #expect(try await afterWrite.coordinator().update(hiding(photoB)).isUnavailable)
        expectIntentKept(afterWrite)
        #expect(await afterWrite.coordinator().refresh().isReady)
        #expect(afterWrite.store.writeAttempts == 1)
        #expect(afterWrite.local.record?.hasUnpublishedChanges == false)
    }

    @Test("T_F18") func tF18() async throws {
        let harness = try trashedHarness()
        harness.store.addRestoreFaults(.applyThenFail(CancellationError()))
        #expect(await harness.coordinator().refresh().isUnavailable)
        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.restores == 1)
    }

    // MARK: - F19 local disk full, database busy, or locked

    @Test("R_F19") func rF19() async throws {
        let harness = try Harness.published()
        harness.local.failLoad = true
        #expect(await harness.coordinator().refresh() == .closed(.localCopyUnavailable))
        #expect(harness.store.writeAttempts == 0)
    }

    @Test("W_F19") func wF19() async throws {
        let harness = try Harness.published()
        harness.local.failSave = true
        #expect(try await harness.coordinator().update(hiding(photoB)) == .closed(.localCopyUnavailable))
        #expect(harness.store.writeAttempts == 0)
        expectServerUnchanged(harness)
    }

    @Test("T_F19") func tF19() async throws {
        let harness = try trashedHarness()
        harness.local.failSave = true
        #expect(await harness.coordinator().refresh() == .closed(.localCopyUnavailable))
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F20 account switch, sign-out, Labs or Smart Search off, wipe

    @Test("R_F20") func rF20() async throws {
        let harness = try Harness.published()
        let fence = harness.fence
        harness.store.addReadFaults(.sideEffect { fence.isCurrent = false })
        #expect(await harness.coordinator().refresh() == .closed(.fenced))
        #expect(harness.local.saves == 0)
    }

    @Test("W_F20") func wF20() async throws {
        // Fenced before dispatch: nothing is sent, and the intent stays dormant in the local copy.
        let beforeDispatch = try Harness.published()
        let fence = beforeDispatch.fence
        let local = try documentHiding([photoA, photoB])
        beforeDispatch.local.set(
            AccountStateLocalRecord(
                binding: testBinding, document: try local.encoded(), lastSealed: nil, published: true,
                hasUnpublishedChanges: true))
        beforeDispatch.store.addReadFaults(.sideEffect { fence.isCurrent = false })
        #expect(await beforeDispatch.coordinator().refresh() == .closed(.fenced))
        #expect(beforeDispatch.store.writeAttempts == 0)
        expectIntentKept(beforeDispatch)

        // Fenced after sealing, right before dispatch: nothing is sent.
        let beforeSend = try Harness.published()
        let beforeSendFence = beforeSend.fence
        beforeSend.sealer.onSeal = { beforeSendFence.isCurrent = false }
        #expect(try await beforeSend.coordinator().update(hiding(photoB)) == .closed(.fenced))
        #expect(beforeSend.store.writeAttempts == 0)
        expectIntentKept(beforeSend)

        // Fenced while the write was in flight: it may finish, but its result is ignored.
        let inFlight = try Harness.published()
        let inFlightFence = inFlight.fence
        inFlight.store.addWriteFaults(.sideEffect { inFlightFence.isCurrent = false })
        #expect(try await inFlight.coordinator().update(hiding(photoB)) == .closed(.fenced))
        #expect(inFlight.store.appliedWrites == 1)
        expectIntentKept(inFlight)
    }

    @Test("T_F20") func tF20() async throws {
        let harness = try trashedHarness()
        let fence = harness.fence
        harness.store.addReadFaults(.sideEffect { fence.isCurrent = false })
        #expect(await harness.coordinator().refresh() == .closed(.fenced))
        #expect(harness.store.restores == 0)
        #expect(harness.store.isTrashed)
    }

    // MARK: - F21 model transition during the step

    @Test("R_F21") func rF21() async throws {
        let harness = try Harness.published()
        var remote = try documentHiding([photoA])
        try remote.setValue("siglip2-v3", for: targetModel, at: stateDate(3_000), deviceID: "mac", nonce: 1)
        harness.store.externalWrite(remote)
        #expect(await harness.coordinator().refresh().document?.value(for: targetModel) == "siglip2-v3")
    }

    @Test("W_F21") func wF21() async throws {
        let harness = try Harness.published()
        var transition = try documentHiding([photoA])
        try transition.setValue("siglip2-v3", for: targetModel, at: stateDate(3_000), deviceID: "mac", nonce: 1)
        harness.store.addWriteFaults(.competingWrite(transition))
        #expect(try await harness.coordinator().update(hiding(photoB)).isReady)
        let remote = try #require(harness.store.remoteDocument)
        #expect(remote.value(for: targetModel) == "siglip2-v3")
        #expect(remote.hiddenPhotos == [photoA, photoB])
    }

    @Test("T_F21") func tF21() async throws {
        let harness = try Harness.published()
        var transition = try documentHiding([photoA])
        try transition.setValue("siglip2-v3", for: targetModel, at: stateDate(3_000), deviceID: "mac", nonce: 1)
        harness.store.externalWrite(transition)
        harness.store.trash()
        #expect(await harness.coordinator().refresh().document?.value(for: targetModel) == "siglip2-v3")
        #expect(harness.store.restores == 1)
    }

    // MARK: - F22 mixed app versions, newer state, or a moved state

    @Test("R_F22") func rF22() async throws {
        let harness = try Harness.published()
        var moved = try documentHiding([photoA])
        try moved.markMoved(to: "new-location", at: stateDate(3_000), deviceID: "mac", nonce: 1)
        harness.store.externalWrite(moved)
        harness.local.set(
            AccountStateLocalRecord(
                binding: testBinding, document: try documentHiding([photoA, photoB]).encoded(), lastSealed: nil,
                published: true,
                hasUnpublishedChanges: true))
        let status = await harness.coordinator().refresh()
        #expect(status.document?.movedTo == "new-location")
        #expect(harness.store.writeAttempts == 0)
    }

    @Test("W_F22") func wF22() async throws {
        let harness = try Harness.published()
        var moved = try documentHiding([photoA])
        try moved.markMoved(to: "new-location", at: stateDate(3_000), deviceID: "mac", nonce: 1)
        harness.store.externalWrite(moved)
        let status = try await harness.coordinator().update(hiding(photoB))
        #expect(status == .moved(moved))
        #expect(harness.store.writeAttempts == 0)
        #expect(harness.store.remoteDocument?.isHidden(photoB) == false)
    }

    @Test("T_F22") func tF22() async throws {
        let harness = try Harness.published()
        var moved = try documentHiding([photoA])
        try moved.markMoved(to: "new-location", at: stateDate(3_000), deviceID: "mac", nonce: 1)
        harness.store.externalWrite(moved)
        harness.store.trash()
        #expect(await harness.coordinator().refresh().document?.movedTo == "new-location")
        #expect(harness.store.restores == 1)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F23 incomplete or stale listing, or no server time

    @Test("R_F23") func rF23() async throws {
        let harness = try Harness.published()
        harness.store.addReadFaults(.fail(DeviceRootOperationError.ambiguousRoot))
        #expect(await harness.coordinator().refresh() == .closed(.ambiguousRoot))
        expectLocalUnchanged(harness)
    }

    @Test("W_F23") func wF23() async throws {
        // An incomplete listing never proves absence, so neither a write nor a first setup creates a file.
        let harness = Harness()
        let incomplete = StoreFault.fail(DeviceRootOperationError.unavailable)
        harness.store.addReadFaults(incomplete, incomplete)
        #expect(try await harness.coordinator().update(hiding(photoB)).isUnavailable)
        #expect(try await harness.coordinator().initialize().isUnavailable)
        #expect(harness.store.writeAttempts == 0)
        #expect(!harness.store.exists)
    }

    @Test("T_F23") func tF23() async throws {
        let harness = try trashedHarness()
        harness.store.addReadFaults(.pass, .fail(DeviceRootOperationError.ambiguousRoot))
        #expect(await harness.coordinator().refresh() == .closed(.ambiguousRoot))
        #expect(harness.store.restores == 1)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - F24 oversized or malformed input

    @Test("R_F24") func rF24() async throws {
        let harness = try Harness.published()
        harness.store.seedRaw(Data(repeating: 0x53, count: 4_096))
        #expect(await harness.coordinator(maximumBytes: 1_024).refresh() == .closed(.oversized))
        expectLocalUnchanged(harness)
    }

    @Test("W_F24") func wF24() async throws {
        let harness = try Harness.published()
        let note = AccountSettingKey<String>(name: "note", encode: { .string($0) }, decode: { $0.stringValue })
        let status = try await harness.coordinator(maximumBytes: 1_024).update {
            try $0.setValue(String(repeating: "x", count: 2_000), for: note, at: stateDate(5_000), deviceID: "iphone")
        }
        #expect(status == .closed(.oversized))
        #expect(harness.store.writeAttempts == 0)
        expectLocalUnchanged(harness)
    }

    @Test("T_F24") func tF24() async throws {
        let harness = try Harness.published()
        harness.store.seedRaw(Data(repeating: 0x53, count: 4_096))
        harness.store.trash()
        #expect(await harness.coordinator(maximumBytes: 1_024).refresh() == .closed(.oversized))
        #expect(harness.store.restores == 1)
        #expect(harness.store.writeAttempts == 0)
    }

    // MARK: - Combined faults

    @Test("F02+F05") func f02F05LostWriteThenAnotherWriter() async throws {
        let harness = try Harness.published()
        harness.store.addWriteFaults(.fail(DeviceRootOperationError.unknownOutcome))
        harness.store.addReadFaults(.pass, .competingWrite(try documentHiding([photoA, photoC], device: "mac")))
        #expect(try await harness.coordinator().update(hiding(photoB)).isReady)
        #expect(harness.store.remoteDocument?.hiddenPhotos == [photoA, photoB, photoC])
    }

    @Test("F03+F07") func f03F07ThrottledWhileSettling() async throws {
        let harness = try Harness.published()
        harness.store.addWriteFaults(.applyThenFail(DeviceRootOperationError.unknownOutcome))
        harness.store.addReadFaults(.pass, .fail(DeviceRootOperationError.rateLimited))
        #expect(try await harness.coordinator().update(hiding(photoB)).isUnavailable)
        expectIntentKept(harness)
        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.writeAttempts == 1)
        #expect(harness.local.record?.hasUnpublishedChanges == false)
    }

    @Test("F12+F20+F22") func f12F20F22TrashDuringAccountAndFormatChange() async throws {
        let harness = try trashedHarness()
        let fence = harness.fence
        harness.store.addRestoreFaults(.sideEffect { fence.isCurrent = false })
        #expect(await harness.coordinator().refresh() == .closed(.fenced))
        #expect(harness.store.writeAttempts == 0)

        fence.isCurrent = true
        harness.store.seedRaw(Data("S2|account|incarnation|state|k0|opaque".utf8))
        #expect(await harness.coordinator().refresh() == .readOnly(format: 2))
        #expect(harness.store.writeAttempts == 0)
    }

    @Test("F14+F16") func f14F16ReplayFromAnotherRootIncarnation() async throws {
        let harness = try Harness.published()
        let replay = Data("S1|account|old-incarnation|state|k0|".utf8) + (try documentHiding([photoC]).encoded())
        harness.store.seedRaw(replay)
        #expect(try await harness.coordinator().update(hiding(photoB)) == .closed(.rejected(.wrongBinding)))
        #expect(harness.store.writeAttempts == 0)
        expectLocalUnchanged(harness)
    }

    @Test("F18+F19") func f18F19RemoteSuccessThenDiskFull() async throws {
        let harness = try Harness.published()
        let local = harness.local
        harness.store.addWriteFaults(.sideEffect { local.failSave = true })
        #expect(try await harness.coordinator().update(hiding(photoB)).isReady)
        #expect(harness.store.remoteDocument?.hiddenPhotos == [photoA, photoB])
        expectIntentKept(harness)

        local.failSave = false
        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.writeAttempts == 1)
        #expect(harness.local.record?.hasUnpublishedChanges == false)
    }

    @Test("F20+F03") func f20F03AccountSwitchWithUnknownOutcome() async throws {
        let harness = try Harness.published()
        let fence = harness.fence
        harness.store.addWriteFaults(.sideEffect { fence.isCurrent = false })
        #expect(try await harness.coordinator().update(hiding(photoB)) == .closed(.fenced))
        expectIntentKept(harness)

        // Account B uses its own coordinator and local copy; account A's intent stays dormant meanwhile.
        fence.isCurrent = true
        #expect(await harness.coordinator().refresh().isReady)
        #expect(harness.store.writeAttempts == 1)
        #expect(harness.local.record?.hasUnpublishedChanges == false)
    }
}
