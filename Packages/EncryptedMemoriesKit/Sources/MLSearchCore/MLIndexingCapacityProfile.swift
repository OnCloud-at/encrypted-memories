import Foundation

/// Platform-neutral limits injected by an adapter. Core owns one scheduling algorithm while the
/// host describes only the sustained-work envelope it can safely offer.
public struct MLIndexingCapacityProfile: Sendable, Equatable {
    public var nativeQuantumAssets: Int
    public var semanticQuantumAssets: Int
    public var automaticTimeSlice: Duration?
    public var rampsNativeParallelism: Bool
    public var cleanQuantaPerRampStep: Int

    public init(
        nativeQuantumAssets: Int,
        semanticQuantumAssets: Int,
        automaticTimeSlice: Duration?,
        rampsNativeParallelism: Bool,
        cleanQuantaPerRampStep: Int = 2
    ) {
        self.nativeQuantumAssets = max(1, nativeQuantumAssets)
        self.semanticQuantumAssets = max(1, semanticQuantumAssets)
        self.automaticTimeSlice = automaticTimeSlice.flatMap { $0 > .zero ? $0 : nil }
        self.rampsNativeParallelism = rampsNativeParallelism
        self.cleanQuantaPerRampStep = max(1, cleanQuantaPerRampStep)
    }

    /// Energy-constrained hosts retain the effective two-asset scheduler used before adaptive
    /// desktop indexing. Live leases still add preemption without raising the work envelope.
    public static let constrained = MLIndexingCapacityProfile(
        nativeQuantumAssets: 2,
        semanticQuantumAssets: 2,
        automaticTimeSlice: nil,
        rampsNativeParallelism: false
    )

    /// Sustained-work hosts receive time-bounded quanta. Hardware capability still provides the
    /// independent native-concurrency ceiling, so this profile contains no device-name knowledge.
    public static let sustained = MLIndexingCapacityProfile(
        nativeQuantumAssets: 32,
        semanticQuantumAssets: 128,
        automaticTimeSlice: .seconds(2),
        rampsNativeParallelism: true
    )
}

public enum MLIndexingQuantumDisposition: Sendable, Equatable {
    case clean
    case resourceYield
    case neutralFailure
}

/// Small value-state controller scoped to one native runtime generation.
public struct MLNativeParallelismRamp: Sendable, Equatable {
    public private(set) var currentParallelism: Int
    public private(set) var cleanQuantumCount: Int

    private let ceiling: Int
    private let cleanQuantaPerStep: Int
    private let isEnabled: Bool

    public init(
        ceiling: Int,
        profile: MLIndexingCapacityProfile
    ) {
        self.ceiling = max(1, ceiling)
        self.cleanQuantaPerStep = profile.cleanQuantaPerRampStep
        self.isEnabled = profile.rampsNativeParallelism
        self.currentParallelism =
            profile.rampsNativeParallelism
            ? 1
            : min(max(1, ceiling), profile.nativeQuantumAssets)
        self.cleanQuantumCount = 0
    }

    public mutating func note(_ disposition: MLIndexingQuantumDisposition) {
        switch disposition {
        case .clean:
            guard isEnabled, currentParallelism < ceiling else { return }
            cleanQuantumCount += 1
            guard cleanQuantumCount >= cleanQuantaPerStep else { return }
            currentParallelism += 1
            cleanQuantumCount = 0
        case .resourceYield:
            currentParallelism = isEnabled ? 1 : min(ceiling, currentParallelism)
            cleanQuantumCount = 0
        case .neutralFailure:
            cleanQuantumCount = 0
        }
    }
}
