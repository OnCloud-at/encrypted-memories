import Foundation

public enum LibraryMemoryHeadroom: Int, Sendable, Comparable, Equatable {
    case unknown = 0
    case healthy = 1
    case constrained = 2
    case critical = 3

    public static func < (lhs: LibraryMemoryHeadroom, rhs: LibraryMemoryHeadroom) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct LibraryNetworkState: Sendable, Equatable {
    public var isReachable: Bool
    public var isConstrained: Bool
    public var isExpensive: Bool

    public init(isReachable: Bool = true, isConstrained: Bool = false, isExpensive: Bool = false) {
        self.isReachable = isReachable
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
    }
}

public enum LibraryExecutionOpportunity: Int, Sendable, Comparable, Equatable {
    case foregroundActive = 0
    case foregroundInactive = 1
    case backgroundPermitted = 2
    case suspended = 3

    public static func < (lhs: LibraryExecutionOpportunity, rhs: LibraryExecutionOpportunity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Privacy-safe process state shared by backup, indexing, cache and prefetch policy. It deliberately
/// cannot carry asset identifiers, filenames, hashes, queries or user content.
public struct LibraryRuntimeSnapshot: Sendable, Equatable {
    public var thermalLevel: LibraryThermalLevel
    public var memoryPressure: MemoryConditions.Pressure
    public var memoryBudgetTier: MemoryBudgetTier
    public var memoryHeadroom: LibraryMemoryHeadroom
    public var isLowPowerMode: Bool
    public var network: LibraryNetworkState
    public var executionOpportunity: LibraryExecutionOpportunity
    public var hasVisibleMediaDemand: Bool
    public var hasActiveUserInteraction: Bool
    public var activeUserTransferCount: Int
    public var generation: UInt64
    public var monotonicUptimeNanoseconds: UInt64

    public init(
        thermalLevel: LibraryThermalLevel = .nominal,
        memoryPressure: MemoryConditions.Pressure = .normal,
        memoryBudgetTier: MemoryBudgetTier = .normal,
        memoryHeadroom: LibraryMemoryHeadroom = .unknown,
        isLowPowerMode: Bool = false,
        network: LibraryNetworkState = LibraryNetworkState(),
        executionOpportunity: LibraryExecutionOpportunity = .foregroundActive,
        hasVisibleMediaDemand: Bool = false,
        hasActiveUserInteraction: Bool = false,
        activeUserTransferCount: Int = 0,
        generation: UInt64 = 0,
        monotonicUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.thermalLevel = thermalLevel
        self.memoryPressure = memoryPressure
        self.memoryBudgetTier = memoryBudgetTier
        self.memoryHeadroom = memoryHeadroom
        self.isLowPowerMode = isLowPowerMode
        self.network = network
        self.executionOpportunity = executionOpportunity
        self.hasVisibleMediaDemand = hasVisibleMediaDemand
        self.hasActiveUserInteraction = hasActiveUserInteraction
        self.activeUserTransferCount = max(0, activeUserTransferCount)
        self.generation = generation
        self.monotonicUptimeNanoseconds = monotonicUptimeNanoseconds
    }

    public static let initial = LibraryRuntimeSnapshot()
}

/// One process-wide state source. Synchronous feature gates read `snapshot()` without an actor hop;
/// actor clients consume a newest-only stream. Session invalidation is atomic with the state reset.
public final class LibraryRuntimeState: @unchecked Sendable {
    public static let shared = LibraryRuntimeState()

    private let lock = NSLock()
    private var current: LibraryRuntimeSnapshot
    private var continuations: [UUID: AsyncStream<LibraryRuntimeSnapshot>.Continuation] = [:]

    public init(initial: LibraryRuntimeSnapshot = .initial) {
        current = initial
    }

    public func snapshot() -> LibraryRuntimeSnapshot {
        lock.withLock { current }
    }

    @discardableResult
    public func update(
        _ transform: (inout LibraryRuntimeSnapshot) -> Void
    ) -> LibraryRuntimeSnapshot {
        let result: (LibraryRuntimeSnapshot, [AsyncStream<LibraryRuntimeSnapshot>.Continuation]) = lock.withLock {
            var next = current
            transform(&next)
            next.activeUserTransferCount = max(0, next.activeUserTransferCount)
            next.generation = current.generation
            // The timestamp describes an accepted semantic transition; it must not itself make a
            // no-op update look different and flood newest-only subscribers.
            next.monotonicUptimeNanoseconds = current.monotonicUptimeNanoseconds
            guard next != current else { return (current, []) }
            next.monotonicUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            current = next
            return (next, Array(continuations.values))
        }
        for continuation in result.1 { continuation.yield(result.0) }
        return result.0
    }

    /// Invalidates callbacks from the previous account/run and resets content-independent demand.
    @discardableResult
    public func beginNewGeneration(
        preservingSystemSignals: Bool = true
    ) -> LibraryRuntimeSnapshot {
        let result: (LibraryRuntimeSnapshot, [AsyncStream<LibraryRuntimeSnapshot>.Continuation]) = lock.withLock {
            let old = current
            let generation = old.generation &+ 1
            current =
                preservingSystemSignals
                ? LibraryRuntimeSnapshot(
                    thermalLevel: old.thermalLevel,
                    memoryPressure: old.memoryPressure,
                    memoryBudgetTier: old.memoryBudgetTier,
                    memoryHeadroom: old.memoryHeadroom,
                    isLowPowerMode: old.isLowPowerMode,
                    network: old.network,
                    executionOpportunity: old.executionOpportunity,
                    generation: generation
                )
                : LibraryRuntimeSnapshot(generation: generation)
            return (current, Array(continuations.values))
        }
        for continuation in result.1 { continuation.yield(result.0) }
        return result.0
    }

    public func updates() -> AsyncStream<LibraryRuntimeSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let initial = lock.withLock { () -> LibraryRuntimeSnapshot in
                continuations[id] = continuation
                return current
            }
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.continuations[id] = nil }
            }
        }
    }
}
