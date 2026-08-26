import XCTest

@testable import GridCore

/// Locks the coalesced render-loop semantics: one render per tick, retry on a failed present, keep
/// ticking while streaming work is pending, stop when idle.
final class GridFramePumpTests: XCTestCase {
    func testFreshPumpWantsAFirstFrame() {
        XCTAssertTrue(GridFramePump().shouldTick)
    }

    func testSuccessfulIdleFrameStopsTheLoop() {
        var pump = GridFramePump()
        XCTAssertFalse(pump.completeTick(presented: true, hasPendingWork: false))
        XCTAssertFalse(pump.shouldTick)
    }

    func testFailedPresentRetriesUntilAFrameLands() {
        // A failed present must keep the pump active so the next drawable can render content.
        var pump = GridFramePump()
        XCTAssertTrue(pump.completeTick(presented: false, hasPendingWork: false))
        XCTAssertTrue(pump.shouldTick)
        XCTAssertFalse(pump.completeTick(presented: true, hasPendingWork: false))
    }

    func testPendingStreamWorkKeepsTicking() {
        var pump = GridFramePump()
        XCTAssertTrue(pump.completeTick(presented: true, hasPendingWork: true))
        XCTAssertTrue(pump.shouldTick)
        XCTAssertFalse(pump.completeTick(presented: true, hasPendingWork: false))
    }

    func testInvalidationReawakensAnIdlePump() {
        var pump = GridFramePump()
        pump.completeTick(presented: true, hasPendingWork: false)
        XCTAssertFalse(pump.shouldTick)
        pump.invalidate()
        XCTAssertTrue(pump.shouldTick)
    }

    func testFreshPumpIsActive() {
        XCTAssertTrue(GridFramePump().isActive)
    }

    func testDeactivatingGatesTicksOffEvenWithPendingWork() {
        var pump = GridFramePump()
        pump.invalidate()
        XCTAssertTrue(pump.shouldTick)
        XCTAssertTrue(pump.setActive(false))  // real transition
        XCTAssertFalse(pump.isActive)
        XCTAssertFalse(pump.shouldTick)  // gated off despite being dirty
    }

    func testInactivePumpNeverKeepsTickingEvenWithPendingStreamWork() {
        var pump = GridFramePump()
        pump.setActive(false)
        // Even "pending work" / a failed present cannot keep an inactive loop running.
        XCTAssertFalse(pump.completeTick(presented: false, hasPendingWork: true))
        XCTAssertFalse(pump.shouldTick)
    }

    func testReactivatingRearmsExactlyOneFrame() {
        var pump = GridFramePump()
        pump.completeTick(presented: true, hasPendingWork: false)  // idle
        pump.setActive(false)
        XCTAssertFalse(pump.shouldTick)
        XCTAssertTrue(pump.setActive(true))  // real transition re-arms
        XCTAssertTrue(pump.shouldTick)  // one frame on return, no external nudge
        XCTAssertFalse(pump.completeTick(presented: true, hasPendingWork: false))  // then settles
    }

    func testRedundantSetActiveIsANoOpTransition() {
        var pump = GridFramePump()
        XCTAssertFalse(pump.setActive(true))  // already active
        pump.completeTick(presented: true, hasPendingWork: false)  // idle
        XCTAssertFalse(pump.setActive(true))  // still active, so no re-arm
        XCTAssertFalse(pump.shouldTick)
    }
}
