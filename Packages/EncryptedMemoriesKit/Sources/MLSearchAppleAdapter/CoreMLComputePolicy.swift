import CoreML
import Foundation
import MLSearchCore

/// Compute-unit policy for Core ML inference.
/// Production inference uses the CPU and Neural Engine. Other choices are available only to debug tests.
public struct CoreMLComputePolicy: Sendable, Equatable {
    public let computeUnits: MLComputeUnits

    /// The production policy: CPU plus Neural Engine.
    public static let `default`: CoreMLComputePolicy = .init(computeUnits: .cpuAndNeuralEngine)

    /// Creates the default production policy.
    public init() {
        self.computeUnits = .cpuAndNeuralEngine
    }

    /// Preserves arbitrary unit selection for debug and test factories.
    private init(computeUnits: MLComputeUnits) {
        self.computeUnits = computeUnits
    }

    /// Converts this policy into a CoreML model configuration that can be passed to `MLModel(configuration:)`.
    public var modelConfiguration: MLModelConfiguration {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        return config
    }
}

#if DEBUG
    /// Debug-only factory for testing alternate compute-unit selections.
    internal extension CoreMLComputePolicy {
        static func debugOnlyTestingFactory(computeUnits: MLComputeUnits) -> CoreMLComputePolicy {
            .init(computeUnits: computeUnits)
        }
    }
#endif
