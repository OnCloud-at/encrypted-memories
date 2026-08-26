import Photos
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import PhotosCore
@testable import UploadCore

final class PhotoLibraryResourceErrorTests: XCTestCase {
    func testMissingPhotoKitResourceBecomesTerminalSourceError() {
        let native = NSError(
            domain: PHPhotosErrorDomain,
            code: PHPhotosError.Code.missingResource.rawValue
        )

        let normalized = PhotoLibraryResourceResolver.normalizedPhotoKitError(
            native,
            filename: "IMG_0001.jpeg"
        )

        XCTAssertEqual(normalized as? UploadError, .fileMissing("IMG_0001.jpeg"))
    }

    func testPhotoKitNetworkFailureRemainsRetryableTransportError() {
        let native = NSError(
            domain: PHPhotosErrorDomain,
            code: PHPhotosError.Code.networkError.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "offline"]
        )

        let normalized = PhotoLibraryResourceResolver.normalizedPhotoKitError(
            native,
            filename: "IMG_0002.mov"
        )

        XCTAssertEqual(
            normalized as? UploadError,
            .transport(code: PHPhotosError.Code.networkError.rawValue, message: "offline")
        )
    }

    func testPhotoKitRequestActivityExtendsItsStallDeadline() async throws {
        let clock = ManualUptime()
        let cancellations = RequestCancellations()
        let liveness = PhotoKitResourceRequestLivenessGuard<Int>(
            stallTimeout: 180,
            pollInterval: 5,
            automaticallyStartsWatchdog: false,
            now: { clock.value },
            cancelRequest: { cancellations.record($0) }
        )
        let request = Task {
            try await liveness.waitForCompletion { 41 }
        }
        while !liveness.hasRegisteredRequest { await Task.yield() }

        clock.advance(by: 179)
        XCTAssertFalse(liveness.checkForStall())
        liveness.markActivity()
        clock.advance(by: 179)
        XCTAssertFalse(liveness.checkForStall())

        liveness.complete(error: nil)
        try await request.value
        XCTAssertEqual(cancellations.values, [])
    }

    func testStalledPhotoKitRequestReleasesHeavyPermitAndRetriesAsTransport() async throws {
        let clock = ManualUptime()
        let cancellations = RequestCancellations()
        let liveness = PhotoKitResourceRequestLivenessGuard<Int>(
            stallTimeout: 180,
            pollInterval: 5,
            automaticallyStartsWatchdog: false,
            now: { clock.value },
            cancelRequest: { cancellations.record($0) }
        )
        let coordinator = LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
        let work = LibraryWorkRequest(
            workload: .backupMaterialization,
            intent: .automatic,
            memoryClass: .large
        )
        let stalled = Task {
            try await coordinator.withHeavyPermit(work) { _ in
                try await liveness.waitForCompletion { 42 }
            }
        }
        while !liveness.hasRegisteredRequest { await Task.yield() }
        let following = Task {
            try await coordinator.withHeavyPermit(work) { _ in "continued" }
        }

        clock.advance(by: 180)
        XCTAssertTrue(liveness.checkForStall())
        do {
            try await stalled.value
            XCTFail("expected PhotoKit inactivity timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
            XCTAssertTrue(BackupSyncRunner.isTransientNetwork(error))
        }
        let followingResult = try await following.value
        XCTAssertEqual(followingResult, "continued")
        XCTAssertEqual(cancellations.values, [42])

        // A late native completion after cancellation is ignored and cannot double-resume.
        liveness.complete(error: nil)
        XCTAssertEqual(cancellations.values, [42])
    }

    func testCancellingPhotoKitWaitResumesWithoutNativeCompletion() async {
        let cancellations = RequestCancellations()
        let liveness = PhotoKitResourceRequestLivenessGuard<Int>(
            automaticallyStartsWatchdog: false,
            cancelRequest: { cancellations.record($0) }
        )
        let request = Task {
            try await liveness.waitForCompletion { 43 }
        }
        while !liveness.hasRegisteredRequest { await Task.yield() }

        request.cancel()
        do {
            try await request.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation itself resumes the callback bridge.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(cancellations.values, [43])
    }
}

private final class ManualUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval = 0

    var value: TimeInterval { lock.withLock { stored } }

    func advance(by interval: TimeInterval) {
        lock.withLock { stored += interval }
    }
}

private final class RequestCancellations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    func record(_ requestID: Int) {
        lock.withLock { stored.append(requestID) }
    }

    var values: [Int] { lock.withLock { stored } }
}
