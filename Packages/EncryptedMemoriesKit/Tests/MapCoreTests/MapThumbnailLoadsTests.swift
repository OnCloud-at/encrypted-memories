import Foundation
import PhotosCore
import Testing

@testable import MapCore

@MainActor
@Suite struct MapThumbnailLoadsTests {
    private let first = PhotoUID(volumeID: "v", nodeID: "first")
    private let second = PhotoUID(volumeID: "v", nodeID: "second")

    /// A load that waits until the test lets it finish, or until the load is cancelled. It counts how often it was
    /// started, and tells the test when a load of a photo has started and when it has returned. Every wait of the test
    /// is bounded, so a load that never arrives fails the test instead of hanging it.
    private final class GatedLoad: @unchecked Sendable {
        private struct Signals {
            let started = AsyncTestSignal()
            let gate = AsyncTestSignal()
            let returned = AsyncTestSignal()
        }

        private let lock = NSLock()
        private var count = 0
        private var signalsByUID: [PhotoUID: Signals] = [:]
        private var cancelledUIDs: Set<PhotoUID> = []

        private func signals(_ uid: PhotoUID) -> Signals {
            lock.withLock {
                if let existing = signalsByUID[uid] { return existing }
                let created = Signals()
                signalsByUID[uid] = created
                return created
            }
        }

        var startCount: Int { lock.withLock { count } }

        func load(_ uid: PhotoUID) async -> String? {
            lock.withLock { count += 1 }
            let signals = signals(uid)
            signals.started.fire()
            _ = await signals.gate.happens()
            lock.withLock { if Task.isCancelled { cancelledUIDs.insert(uid) } }
            signals.returned.fire()
            return "image-\(uid.nodeID)"
        }

        /// Whether the load of the photo was cancelled when it returned.
        func wasCancelled(_ uid: PhotoUID) -> Bool { lock.withLock { cancelledUIDs.contains(uid) } }

        func waitUntilStarted(_ uid: PhotoUID) async { _ = await signals(uid).started.happens() }
        func finish(_ uid: PhotoUID) { signals(uid).gate.fire() }
        func waitUntilReturned(_ uid: PhotoUID) async { _ = await signals(uid).returned.happens() }
    }

    /// The images that reached a photo, in order, with a wait for the n-th one.
    private final class Applied: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        private var signals: [Int: AsyncTestSignal] = [:]

        var values: [String] { lock.withLock { entries } }

        func record(_ image: String, _ uid: PhotoUID) {
            let reached = lock.withLock { () -> AsyncTestSignal? in
                entries.append("\(uid.nodeID):\(image)")
                return signals[entries.count]
            }
            reached?.fire()
        }

        func wait(forCount target: Int) async {
            let signal = lock.withLock { () -> AsyncTestSignal in
                if let existing = signals[target] { return existing }
                let created = AsyncTestSignal()
                signals[target] = created
                if entries.count >= target { created.fire() }
                return created
            }
            // A load that never applies ends the wait at the hang limit, and the checks that follow fail.
            _ = await signal.happens()
        }
    }

    /// Returns once every continuation that was already waiting on the main actor has run: a load of a photo that
    /// is not otherwise used goes through the loads and applies its image, which takes a full round trip.
    private func drainMainActor(of loads: MapThumbnailLoads<String>) async {
        let drain = Applied()
        let probe = PhotoUID(volumeID: "v", nodeID: "drain-probe")
        loads.requestIfNeeded(probe, load: { _ in "drained" }, apply: drain.record)
        await drain.wait(forCount: 1)
    }

    @Test func aFinishedLoadAppliesItsImageToItsPhoto() async {
        let loads = MapThumbnailLoads<String>()
        let gated = GatedLoad()
        let applied = Applied()

        loads.requestIfNeeded(first, load: gated.load, apply: applied.record)
        await gated.waitUntilStarted(first)
        gated.finish(first)
        await applied.wait(forCount: 1)

        #expect(applied.values == ["first:image-first"])
    }

    @Test func aSecondRequestForAPhotoThatIsLoadingStartsNoSecondLoad() async {
        let loads = MapThumbnailLoads<String>()
        let gated = GatedLoad()
        let applied = Applied()

        loads.requestIfNeeded(first, load: gated.load, apply: applied.record)
        await gated.waitUntilStarted(first)
        loads.requestIfNeeded(first, load: gated.load, apply: applied.record)
        gated.finish(first)
        await applied.wait(forCount: 1)

        #expect(gated.startCount == 1)
        #expect(applied.values == ["first:image-first"])
    }

    @Test func aPhotoCanBeRequestedAgainAfterItsLoadFinished() async {
        let loads = MapThumbnailLoads<String>()
        let gated = GatedLoad()
        let applied = Applied()
        loads.requestIfNeeded(first, load: gated.load, apply: applied.record)
        await gated.waitUntilStarted(first)
        gated.finish(first)
        await applied.wait(forCount: 1)

        // The slot is free again once the load ended, so another request starts a new load. Its gate is open.
        loads.requestIfNeeded(first, load: gated.load, apply: applied.record)
        await applied.wait(forCount: 2)

        #expect(gated.startCount == 2)
    }

    @Test func aCancelledLoadNeverAppliesItsImage() async {
        let loads = MapThumbnailLoads<String>()
        let gated = GatedLoad()
        let applied = Applied()
        loads.requestIfNeeded(first, load: gated.load, apply: applied.record)
        loads.requestIfNeeded(second, load: gated.load, apply: applied.record)
        await gated.waitUntilStarted(first)
        await gated.waitUntilStarted(second)

        loads.cancel([first])
        gated.finish(first)
        gated.finish(second)
        await gated.waitUntilReturned(first)
        await gated.waitUntilReturned(second)
        await applied.wait(forCount: 1)
        await drainMainActor(of: loads)

        #expect(applied.values == ["second:image-second"], "only the load that stayed is applied")
    }

    @Test func releasingTheLoadsCancelsEveryLoadThatIsStillRunning() async {
        let gated = GatedLoad()
        let applied = Applied()
        var loads: MapThumbnailLoads<String>? = MapThumbnailLoads<String>()
        loads?.requestIfNeeded(first, load: gated.load, apply: applied.record)
        await gated.waitUntilStarted(first)

        loads = nil
        gated.finish(first)
        await gated.waitUntilReturned(first)
        // A load of another photo on another set applies after the released one returned.
        let other = MapThumbnailLoads<String>()
        other.requestIfNeeded(second, load: gated.load, apply: applied.record)
        await gated.waitUntilStarted(second)
        gated.finish(second)
        await applied.wait(forCount: 1)

        #expect(applied.values == ["second:image-second"])
        #expect(gated.wasCancelled(first), "the load of the released set was told to stop")
        #expect(!gated.wasCancelled(second), "a load of a set that is still alive is not")
    }

    /// A cancelled load of a photo can return after a newer load of the same photo started. It must leave the slot of
    /// the newer load alone: the newer load stays the one load of its photo, a cancel reaches it, and so does a release.
    @Test func aCancelledLoadThatReturnsLateLeavesTheNewerLoadOfItsPhotoInPlace() async {
        let loads = MapThumbnailLoads<String>()
        let older = GatedLoad()
        let newer = GatedLoad()
        let third = GatedLoad()
        let applied = Applied()
        loads.requestIfNeeded(first, load: older.load, apply: applied.record)
        await older.waitUntilStarted(first)
        loads.cancel([first])
        loads.requestIfNeeded(first, load: newer.load, apply: applied.record)
        await newer.waitUntilStarted(first)
        await older.waitUntilReturned(first)
        await drainMainActor(of: loads)

        // The newer load still owns its photo, so another request starts nothing.
        loads.requestIfNeeded(first, load: third.load, apply: applied.record)
        await drainMainActor(of: loads)
        #expect(third.startCount == 0, "the photo still has its newer load")

        // And the cancel of the pin reaches the newer load.
        loads.cancel([first])
        newer.finish(first)
        await newer.waitUntilReturned(first)
        await drainMainActor(of: loads)
        #expect(newer.wasCancelled(first), "the cancel of the pin stops the newer load")
        #expect(applied.values.isEmpty, "no load of the photo applied an image")
    }

    @Test func aCancelledLoadThatReturnsLateDoesNotHideTheNewerLoadFromTheRelease() async {
        let older = GatedLoad()
        let newer = GatedLoad()
        let applied = Applied()
        var loads: MapThumbnailLoads<String>? = MapThumbnailLoads<String>()
        loads?.requestIfNeeded(first, load: older.load, apply: applied.record)
        await older.waitUntilStarted(first)
        loads?.cancel([first])
        loads?.requestIfNeeded(first, load: newer.load, apply: applied.record)
        await newer.waitUntilStarted(first)
        await older.waitUntilReturned(first)
        if let loads { await drainMainActor(of: loads) }

        loads = nil
        newer.finish(first)
        await newer.waitUntilReturned(first)

        #expect(newer.wasCancelled(first), "releasing the loads stops the newer load")
    }
}
