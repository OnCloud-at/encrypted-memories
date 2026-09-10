import Foundation
import XCTest

@testable import PhotosCore

final class OfflineLibraryStatsCoordinatorTests: XCTestCase {
    private final class StatusSource: @unchecked Sendable {
        private let lock = NSLock()
        private var value: OfflineCacheStatus
        private var reads = 0
        private let firstStarted: DispatchSemaphore?
        private let releaseFirst: DispatchSemaphore?

        init(
            _ value: OfflineCacheStatus,
            firstStarted: DispatchSemaphore? = nil,
            releaseFirst: DispatchSemaphore? = nil
        ) {
            self.value = value
            self.firstStarted = firstStarted
            self.releaseFirst = releaseFirst
        }

        func set(_ value: OfflineCacheStatus) {
            lock.withLock { self.value = value }
        }

        func read() -> OfflineCacheStatus {
            let (snapshot, isFirst) = lock.withLock { () -> (OfflineCacheStatus, Bool) in
                reads += 1
                return (value, reads == 1)
            }
            if isFirst {
                firstStarted?.signal()
                releaseFirst?.wait()
            }
            return snapshot
        }

        var readCount: Int { lock.withLock { reads } }
    }

    private static func status(_ value: Int) -> OfflineCacheStatus {
        OfflineCacheStatus(
            totalAssets: value,
            metadataRows: value,
            thumbnailsOnDisk: value,
            cacheSizeBytes: Int64(value)
        )
    }

    func testBlockedMeasurementRunsOffMainActorAndOverlappingRefreshesCoalesce() async {
        let coordinator = OfflineLibraryStatsCoordinator()
        let session = coordinator.beginSession()
        let demand = try! XCTUnwrap(coordinator.requestRefresh(in: session))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let source = StatusSource(Self.status(3), firstStarted: started, releaseFirst: release)

        let first = Task {
            await coordinator.refresh(in: session, satisfying: demand) { source.read() }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        let secondDemand = try! XCTUnwrap(coordinator.requestRefresh(in: session))
        let second = Task {
            await coordinator.refresh(in: session, satisfying: secondDemand) { source.read() }
        }
        let mainActorValue = await Task { @MainActor in 42 }.value
        XCTAssertEqual(mainActorValue, 42)

        release.signal()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult?.status, Self.status(3))
        XCTAssertEqual(secondResult?.status, Self.status(3))
        XCTAssertEqual(source.readCount, 1)
        await coordinator.stopAndJoin(session)
    }

    func testTwoOverlappingStopsBothJoinTheSameNonCooperativeReader() async {
        let coordinator = OfflineLibraryStatsCoordinator()
        let session = coordinator.beginSession()
        let demand = try! XCTUnwrap(coordinator.requestRefresh(in: session))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let firstStopEntered = DispatchSemaphore(value: 0)
        let secondStopEntered = DispatchSemaphore(value: 0)
        let firstStopFinished = DispatchSemaphore(value: 0)
        let secondStopFinished = DispatchSemaphore(value: 0)
        let source = StatusSource(Self.status(1), firstStarted: started, releaseFirst: release)

        let refresh = Task {
            await coordinator.refresh(in: session, satisfying: demand) { source.read() }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let firstStop = Task {
            firstStopEntered.signal()
            await coordinator.stopAndJoin(session)
            firstStopFinished.signal()
        }
        let secondStop = Task {
            secondStopEntered.signal()
            await coordinator.stopAndJoin(session)
            secondStopFinished.signal()
        }

        XCTAssertEqual(firstStopEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondStopEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(firstStopFinished.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertEqual(secondStopFinished.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()

        let refreshResult = await refresh.value
        XCTAssertNil(refreshResult)
        await firstStop.value
        await secondStop.value
        XCTAssertEqual(source.readCount, 1)
    }

    func testMutationDuringBlockedMeasurementRunsOneFollowUpAndReturnsCurrentStats() async {
        let coordinator = OfflineLibraryStatsCoordinator()
        let session = coordinator.beginSession()
        let firstDemand = try! XCTUnwrap(coordinator.requestRefresh(in: session))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let oldStatus = Self.status(1)
        let currentStatus = Self.status(9)
        let source = StatusSource(oldStatus, firstStarted: started, releaseFirst: release)

        let first = Task {
            await coordinator.refresh(in: session, satisfying: firstDemand) { source.read() }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        source.set(currentStatus)
        let mutationDemand = try! XCTUnwrap(coordinator.markDirty(in: session))
        let afterMutation = Task {
            await coordinator.refresh(in: session, satisfying: mutationDemand) { source.read() }
        }
        release.signal()

        let firstResult = await first.value
        let afterMutationResult = await afterMutation.value
        XCTAssertEqual(firstResult?.status, currentStatus)
        XCTAssertEqual(afterMutationResult?.status, currentStatus)
        XCTAssertEqual(source.readCount, 2)
        await coordinator.stopAndJoin(session)
    }

    func testDelayedCallerReusesCompletedDemandButNewRequestAndMutationReadAgain() async throws {
        let coordinator = OfflineLibraryStatsCoordinator()
        let session = coordinator.beginSession()
        let demand = try XCTUnwrap(coordinator.requestRefresh(in: session))
        let source = StatusSource(Self.status(1))
        let initial = await coordinator.refresh(in: session, satisfying: demand) { source.read() }
        let delayed = await coordinator.refresh(in: session, satisfying: demand) { source.read() }
        XCTAssertEqual(initial, delayed)
        XCTAssertEqual(source.readCount, 1)

        source.set(Self.status(2))
        let newDemand = try XCTUnwrap(coordinator.requestRefresh(in: session))
        let fresh = await coordinator.refresh(in: session, satisfying: newDemand) { source.read() }
        XCTAssertEqual(fresh?.status, Self.status(2))
        XCTAssertEqual(source.readCount, 2)

        source.set(Self.status(3))
        let mutation = try XCTUnwrap(coordinator.markDirty(in: session))
        let afterMutation = await coordinator.refresh(in: session, satisfying: demand) { source.read() }
        let delayedMutation = await coordinator.refresh(in: session, satisfying: mutation) { source.read() }
        XCTAssertEqual(afterMutation, delayedMutation)
        XCTAssertEqual(afterMutation?.status, Self.status(3))
        XCTAssertEqual(source.readCount, 3)
        await coordinator.stopAndJoin(session)
    }

    func testStoppingNewSessionJoinsInheritedOlderReader() async throws {
        let coordinator = OfflineLibraryStatsCoordinator()
        let oldSession = coordinator.beginSession()
        let oldDemand = try XCTUnwrap(coordinator.requestRefresh(in: oldSession))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let source = StatusSource(Self.status(1), firstStarted: started, releaseFirst: release)
        let refresh = Task {
            await coordinator.refresh(in: oldSession, satisfying: oldDemand) { source.read() }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let newSession = coordinator.beginSession()
        let stop = Task {
            await coordinator.stopAndJoin(newSession)
            finished.signal()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while coordinator.currentDemand(in: newSession) != nil, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertNil(coordinator.currentDemand(in: newSession))
        XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        await stop.value
        let result = await refresh.value
        XCTAssertNil(result)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(source.readCount, 1)
    }

    func testStaleStopDoesNotJoinBlockedNewerSessionReader() async throws {
        let coordinator = OfflineLibraryStatsCoordinator()
        let oldSession = coordinator.beginSession()
        let newSession = coordinator.beginSession()
        let demand = try XCTUnwrap(coordinator.requestRefresh(in: newSession))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let source = StatusSource(Self.status(2), firstStarted: started, releaseFirst: release)
        let refresh = Task {
            await coordinator.refresh(in: newSession, satisfying: demand) { source.read() }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let staleStop = Task {
            await coordinator.stopAndJoin(oldSession)
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertNotNil(coordinator.currentDemand(in: newSession))
        release.signal()
        await staleStop.value
        let result = await refresh.value
        XCTAssertEqual(result?.status, Self.status(2))
        await coordinator.stopAndJoin(newSession)
    }

    func testNewSessionWaitsForOldReaderAndStaleStopCannotCloseIt() async {
        let coordinator = OfflineLibraryStatsCoordinator()
        let oldSession = coordinator.beginSession()
        let oldDemand = try! XCTUnwrap(coordinator.requestRefresh(in: oldSession))
        let oldStarted = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let oldSource = StatusSource(Self.status(1), firstStarted: oldStarted, releaseFirst: releaseOld)
        let newSource = StatusSource(Self.status(2))

        let oldRefresh = Task {
            await coordinator.refresh(in: oldSession, satisfying: oldDemand) { oldSource.read() }
        }
        XCTAssertEqual(oldStarted.wait(timeout: .now() + 2), .success)

        let newSession = coordinator.beginSession()
        let newDemand = try! XCTUnwrap(coordinator.requestRefresh(in: newSession))
        let staleStop = Task { await coordinator.stopAndJoin(oldSession) }
        let newRefresh = Task {
            await coordinator.refresh(in: newSession, satisfying: newDemand) { newSource.read() }
        }
        XCTAssertEqual(newSource.readCount, 0)

        releaseOld.signal()
        let oldResult = await oldRefresh.value
        XCTAssertNil(oldResult)
        await staleStop.value
        let newResult = await newRefresh.value
        XCTAssertEqual(newResult?.status, Self.status(2))
        XCTAssertEqual(oldSource.readCount, 1)
        XCTAssertEqual(newSource.readCount, 1)
        await coordinator.stopAndJoin(newSession)
    }
}
