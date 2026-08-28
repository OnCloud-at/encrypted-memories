import Foundation
import ProtonDriveSDK
import Testing
import UploadCore

@testable import ProtonDriveBackend

@Suite("SDK event cursor adaptation")
struct SDKEventCursorAccumulatorTests {
    @Test func nilCursorIsSeededByCursorAdvancedEvent() throws {
        let accumulator = SDKEventCursorAccumulator(cursor: nil)

        accumulator.receive(.success(SDKDriveEvent(eventId: "event-7", kind: .cursorAdvanced)))

        #expect(
            try accumulator.result()
                == SDKEventCursorResult(
                    cursor: "event-7",
                    requiresAuthoritativeRefresh: false,
                    scopeAccessLost: false
                ))
    }

    @Test func emptyResumedEnumerationKeepsInputCursor() throws {
        let accumulator = SDKEventCursorAccumulator(cursor: "event-7")

        #expect(try accumulator.result().cursor == "event-7")
    }

    @Test func streamedEventsRetainOnlyLatestCursor() throws {
        let accumulator = SDKEventCursorAccumulator(cursor: "event-7")
        let uid = SDKNodeUid(volumeID: "volume", nodeID: "node")

        accumulator.receive(
            .success(
                SDKDriveEvent(
                    eventId: "event-8",
                    kind: .nodeUpdated(
                        nodeUid: uid,
                        parentNodeUid: nil,
                        isTrashed: false,
                        isShared: false
                    )
                )))
        accumulator.receive(.success(SDKDriveEvent(eventId: "event-9", kind: .sharedWithMeUpdated)))
        accumulator.receive(
            .success(
                SDKDriveEvent(
                    eventId: "event-10",
                    kind: .nodeDeleted(nodeUid: uid, parentNodeUid: nil)
                )))

        #expect(try accumulator.result().cursor == "event-10")
    }

    @Test func continuityLossKeepsLastCommittableCursorAndForcesFullInventory() throws {
        let accumulator = SDKEventCursorAccumulator(cursor: "event-7")

        accumulator.receive(.success(SDKDriveEvent(eventId: "event-12", kind: .continuityLost)))

        #expect(
            try accumulator.result()
                == SDKEventCursorResult(
                    cursor: "event-7",
                    requiresAuthoritativeRefresh: true,
                    scopeAccessLost: false
                ))
    }

    @Test func callbacksAfterContinuityLossCannotAdvanceTheCommittableCursor() throws {
        let accumulator = SDKEventCursorAccumulator(cursor: "event-7")

        accumulator.receive(.success(SDKDriveEvent(eventId: "event-8", kind: .continuityLost)))
        accumulator.receive(.success(SDKDriveEvent(eventId: "event-9", kind: .cursorAdvanced)))

        #expect(
            try accumulator.result()
                == SDKEventCursorResult(
                    cursor: "event-7",
                    requiresAuthoritativeRefresh: true,
                    scopeAccessLost: false
                ))
    }

    @Test func continuityLossWithoutASeedDoesNotInventACommittableCursor() throws {
        let accumulator = SDKEventCursorAccumulator(cursor: nil)

        accumulator.receive(.success(SDKDriveEvent(eventId: "event-12", kind: .continuityLost)))

        #expect(
            try accumulator.result()
                == SDKEventCursorResult(
                    cursor: nil,
                    requiresAuthoritativeRefresh: true,
                    scopeAccessLost: false
                ))
    }

    @Test func scopeAccessLossDoesNotAdvanceOrAcceptLaterCursor() throws {
        let accumulator = SDKEventCursorAccumulator(cursor: "event-7")

        accumulator.receive(.success(SDKDriveEvent(eventId: "event-8", kind: .scopeAccessLost)))
        accumulator.receive(.success(SDKDriveEvent(eventId: "event-9", kind: .cursorAdvanced)))

        #expect(
            try accumulator.result()
                == SDKEventCursorResult(
                    cursor: "event-7",
                    requiresAuthoritativeRefresh: false,
                    scopeAccessLost: true
                ))
    }

    @Test func callbackFailureRejectsPartialCursor() {
        struct ExpectedFailure: Error {}
        let accumulator = SDKEventCursorAccumulator(cursor: "event-7")

        accumulator.receive(.success(SDKDriveEvent(eventId: "event-8", kind: .cursorAdvanced)))
        accumulator.receive(.failure(ExpectedFailure()))
        accumulator.receive(.success(SDKDriveEvent(eventId: "event-9", kind: .cursorAdvanced)))

        #expect(throws: ExpectedFailure.self) {
            try accumulator.result()
        }
    }

    @Test func missingSeedCursorFailsClosed() {
        let accumulator = SDKEventCursorAccumulator(cursor: nil)

        #expect(throws: SDKEventCursorError.self) {
            try accumulator.result()
        }
    }
}

@Suite("SDK upload file-system error policy")
struct SDKUploadFileSystemErrorPolicyTests {
    @Test func notFoundUsesExistingSourceMissingDomain() {
        let mapped = DriveSDKBridge.uploadFileSystemError(.notFound, filename: "photo.heic")

        #expect(mapped as? UploadCore.UploadError == .fileMissing("photo.heic"))
    }

    @Test func permissionDeniedUsesExistingPermissionDomain() {
        let mapped = DriveSDKBridge.uploadFileSystemError(.permissionDenied, filename: "photo.heic")

        #expect(mapped as? UploadCore.UploadError == .permissionDenied("photo.heic"))
    }

    @Test func outOfSpaceUsesDurableDeviceStoragePressureDomain() {
        let mapped = DriveSDKBridge.uploadFileSystemError(.outOfSpace, filename: "video.mov")

        #expect(mapped as? BackupTempFileStore.BackupTempFileError == .diskBudgetExceeded)
    }

    @Test func unknownFileSystemCodeKeepsGenericFallbackAvailable() {
        #expect(DriveSDKBridge.uploadFileSystemError(.unknown, filename: "photo.heic") == nil)
    }
}
