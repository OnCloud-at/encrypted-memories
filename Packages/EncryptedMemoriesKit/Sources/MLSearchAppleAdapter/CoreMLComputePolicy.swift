import CoreML
import Foundation
import MLSearchCore
import PhotosCore

/// Compute-unit policy for Core ML inference.
/// Foreground inference uses CPU and Neural Engine; iOS background inference uses CPU only.
public struct CoreMLComputePolicy: Sendable, Equatable {
    public let computeUnits: MLComputeUnits

    /// The production policy: CPU plus Neural Engine.
    public static let `default`: CoreMLComputePolicy = .init(computeUnits: .cpuAndNeuralEngine)

    static var requiresCPUOnly: Bool {
        #if os(iOS)
            LibraryRuntimeState.shared.snapshot().executionOpportunity >= .backgroundPermitted
        #else
            false
        #endif
    }

    func resolved(requiresCPUOnly: Bool) -> Self {
        requiresCPUOnly ? .init(computeUnits: .cpuOnly) : self
    }

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
