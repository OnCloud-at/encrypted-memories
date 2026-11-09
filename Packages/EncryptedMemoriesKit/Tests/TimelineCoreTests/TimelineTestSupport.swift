import Foundation

@testable import TimelineCore

var timelineTestUTCCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

/// Shared deterministic clock for refresh and scroll-label lifecycle tests.
final class TimelineRefreshTestClock: @unchecked Sendable {
    private struct Sleep {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var sleepers: [UUID: Sleep] = [:]
    private var requests: [Duration] = []

    var dependency: TimelineRefreshClock {
        .init(
            now: { self.now }, sleep: { try await self.sleep(for: $0) },
            sleepUntil: { try await self.sleep(until: $0) }
        )
    }

    var now: ContinuousClock.Instant { lock.withLock { instant } }
    var requestedSleeps: [Duration] { lock.withLock { requests } }
    var pendingSleeps: Int { lock.withLock { sleepers.count } }

    @discardableResult
    func advanceToNextSleep() -> Bool {
        guard let deadline = lock.withLock({ sleepers.values.map(\.deadline).min() }) else { return false }
        advance(by: max(.zero, deadline - now))
        return true
    }

    func advance(by duration: Duration) {
        let completed = lock.withLock {
            instant += duration
            let due = sleepers.filter { $0.value.deadline <= instant }
            for id in due.keys { sleepers.removeValue(forKey: id) }
            return due.values.map(\.continuation)
        }
        for continuation in completed { continuation.resume() }
    }

    func waitForSleepCount(_ count: Int) async -> Bool {
        let timeout = ContinuousClock.now + .seconds(5)
        while requestedSleeps.count < count, ContinuousClock.now < timeout { await Task.yield() }
        return requestedSleeps.count >= count
    }

    private func sleep(for duration: Duration) async throws {
        try await sleep(until: now + duration)
    }

    private func sleep(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let admission = lock.withLock {
                    guard !Task.isCancelled else { return (cancelled: true, elapsed: false) }
                    requests.append(max(.zero, deadline - instant))
                    guard deadline > instant else { return (cancelled: false, elapsed: true) }
                    sleepers[id] = Sleep(deadline: deadline, continuation: continuation)
                    return (cancelled: false, elapsed: false)
                }
                if admission.cancelled {
                    continuation.resume(throwing: CancellationError())
                } else if admission.elapsed {
                    continuation.resume()
                }
            }
        } onCancel: {
            let removed = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
            removed?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// Shared thread-safe counter for inventory calls and build cancellation.
final class TimelineTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
    var value: Int { lock.withLock { count } }
}
