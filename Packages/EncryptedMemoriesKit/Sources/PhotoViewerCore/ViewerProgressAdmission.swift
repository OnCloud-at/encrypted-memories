import Foundation

/// Bounds callback-to-actor progress traffic for one viewer load.
///
/// The provider may invoke its callback from any queue and may report values after the load has
/// ended. Admission is therefore lock-owned and closes independently of the consumer's actor hop.
public final class ViewerProgressAdmission: @unchecked Sendable {
    public struct Sample: Equatable, Sendable {
        fileprivate let owner: UUID
        public let step: Int
        public let fraction: Double

        fileprivate init(owner: UUID, step: Int) {
            self.owner = owner
            self.step = step
            self.fraction = Double(step) / 100
        }
    }

    private let lock = NSLock()
    private var isClosed = false
    private var lastStep = -1
    private let owner = UUID()

    public init() {}

    /// Admits at most one sample per whole-percent step, preserving monotonic progress.
    /// Non-finite input is rejected; finite input is clamped to 0...1 before quantization.
    @discardableResult
    public func admit(_ value: Double) -> Sample? {
        guard value.isFinite else { return nil }
        let clamped = min(1, max(0, value))
        let step = Int((clamped * 100).rounded(.down))
        return lock.withLock {
            guard !isClosed, step > lastStep else { return nil }
            lastStep = step
            return Sample(owner: owner, step: step)
        }
    }

    /// Returns false for an older queued publication or any publication after closure.
    public func isCurrent(_ sample: Sample) -> Bool {
        lock.withLock { !isClosed && sample.owner == owner && sample.step == lastStep }
    }

    /// Closes admission for the load. Repeated calls are harmless.
    public func close() {
        lock.withLock { isClosed = true }
    }
}
