import Foundation
import PhotosCore

public struct MLPipelineID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let semanticSearch = MLPipelineID(rawValue: "semanticSearch")
    public static let nativeSearch = MLPipelineID(rawValue: "nativeSearch")
    public static let people = MLPipelineID(rawValue: "people")
    public static let pets = MLPipelineID(rawValue: "pets")
}

public struct MLStageID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum MLModelRole: String, Codable, Hashable, Sendable {
    case dualEncoder
    case imageEncoder
    case textEncoder
    case regionDetector
    case regionEmbedder
    case classifier
    case textRecognizer
    case featurePrinter
    case qualityAnalyzer
    case maskGenerator
}

public enum MLStageProvider: Codable, Equatable, Hashable, Sendable {
    case model(id: MLModelID, role: MLModelRole)
    case native(
        kind: MLNativeAnalysisKind,
        implementationIdentifier: String,
        requestRevision: String
    )
}

/// Operation semantics are Core data, not platform branches. Each embedding namespace identifies
/// an independent vector space so stores and schedulers can isolate their records.
public enum MLStageOperation: Sendable, Equatable, Codable {
    case imageEmbedding(namespace: String)
    case textEmbedding(namespace: String)
    case regionDetection(labels: [String])
    case regionEmbedding(namespace: String)
    case nativeAnalysis(MLNativeAnalysisKind)
}

/// Input routing is explicit Core data. A detector can fan out only matching regions to separate
/// face, cat, dog or future embedders without model-name switches in platform code.
public enum MLStageInput: Sendable, Equatable, Codable {
    case asset
    case regions(producedBy: MLStageID, matchingLabels: [String])
}

public struct MLPipelineStage: Sendable, Equatable, Codable {
    public let id: MLStageID
    public let provider: MLStageProvider
    public let operation: MLStageOperation
    public let input: MLStageInput
    public let dependsOn: [MLStageID]
    public let output: MLAnalysisOutputDescriptor?

    public var modelID: MLModelID? {
        guard case .model(let id, _) = provider else { return nil }
        return id
    }

    public init(
        id: MLStageID,
        provider: MLStageProvider,
        operation: MLStageOperation,
        input: MLStageInput = .asset,
        dependsOn: [MLStageID] = [],
        output: MLAnalysisOutputDescriptor? = nil
    ) {
        self.id = id
        self.provider = provider
        self.operation = operation
        self.input = input
        self.dependsOn = dependsOn
        self.output = output
    }
}

public struct MLPipelineDefinition: Sendable, Equatable, Codable {
    public let id: MLPipelineID
    public let feature: AppFeatureID
    public let stages: [MLPipelineStage]

    public init(id: MLPipelineID, feature: AppFeatureID, stages: [MLPipelineStage]) throws {
        guard !stages.isEmpty else { throw MLPipelineDefinitionError.empty }
        let ids = stages.map(\.id)
        guard Set(ids).count == ids.count else { throw MLPipelineDefinitionError.duplicateStage }
        let known = Set(ids)
        guard stages.allSatisfy({ Set($0.dependsOn).isSubset(of: known) && !$0.dependsOn.contains($0.id) }) else {
            throw MLPipelineDefinitionError.invalidDependency
        }
        let stagesByID = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0) })
        for stage in stages {
            guard Self.hasValidProvider(stage) else {
                throw MLPipelineDefinitionError.providerRoleMismatch(stage.id)
            }
            guard Self.hasValidOutput(stage) else {
                throw MLPipelineDefinitionError.outputMismatch(stage.id)
            }
            guard Self.hasValidInput(stage, stagesByID: stagesByID) else {
                throw MLPipelineDefinitionError.invalidInput
            }
        }
        guard Self.isAcyclic(stages) else { throw MLPipelineDefinitionError.cycle }
        self.id = id
        self.feature = feature
        self.stages = stages
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case feature
        case stages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(MLPipelineID.self, forKey: .id),
            feature: container.decode(AppFeatureID.self, forKey: .feature),
            stages: container.decode([MLPipelineStage].self, forKey: .stages)
        )
    }

    private static func isAcyclic(_ stages: [MLPipelineStage]) -> Bool {
        let dependencies = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, Set($0.dependsOn)) })
        var resolved: Set<MLStageID> = []
        while resolved.count < stages.count {
            let ready = stages.map(\.id).filter {
                !resolved.contains($0) && (dependencies[$0] ?? []).isSubset(of: resolved)
            }
            guard !ready.isEmpty else { return false }
            resolved.formUnion(ready)
        }
        return true
    }

    private static func hasValidProvider(_ stage: MLPipelineStage) -> Bool {
        switch stage.provider {
        case .model(_, let role):
            return stage.operation.accepts(role: role)
        case .native(let kind, let identifier, let revision):
            guard !identifier.isEmpty, !revision.isEmpty,
                case .nativeAnalysis(let operationKind) = stage.operation
            else { return false }
            return kind == operationKind
        }
    }

    private static func hasValidOutput(_ stage: MLPipelineStage) -> Bool {
        guard let output = stage.output else {
            if case .nativeAnalysis = stage.operation { return false }
            return true
        }
        return stage.operation.accepts(output: output)
    }

    private static func hasValidInput(
        _ stage: MLPipelineStage,
        stagesByID: [MLStageID: MLPipelineStage]
    ) -> Bool {
        guard case .regions(let producerID, let matchingLabels) = stage.input else { return true }
        guard !matchingLabels.isEmpty,
            stage.dependsOn.contains(producerID),
            let producer = stagesByID[producerID]
        else { return false }

        let producedLabels: [String]
        let producedSpecies: Set<MLRegionSpecies>
        switch (producer.operation, producer.output) {
        case (.regionDetection(let labels), _):
            producedLabels = labels
            producedSpecies = []
        case (_, .regions(let labels, let species, _)):
            producedLabels = labels
            producedSpecies = Set(species)
        default:
            return false
        }
        guard Set(matchingLabels).isSubset(of: Set(producedLabels)) else { return false }

        guard case .regionEmbedding(_, let requiredSpecies) = stage.output,
            let requiredSpecies
        else { return true }
        return producedSpecies.contains(requiredSpecies)
            && matchingLabels.contains(requiredSpecies.rawValue)
    }
}

public enum MLPipelineDefinitionError: Error, Equatable {
    case empty
    case duplicateStage
    case invalidDependency
    case invalidInput
    case providerRoleMismatch(MLStageID)
    case outputMismatch(MLStageID)
    case cycle
}

/// Versioned envelope for persisted derived pipeline configuration. A schema mismatch resets only
/// the derived pipeline state, which can always be rebuilt from the current catalog.
public struct MLPipelineManifest: Sendable, Equatable, Codable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let definitions: [MLPipelineDefinition]

    public init(schemaVersion: Int = supportedSchemaVersion, definitions: [MLPipelineDefinition]) {
        self.schemaVersion = schemaVersion
        self.definitions = definitions
    }

    public static func decodeDerivedState(
        from data: Data,
        scope: MLDerivedStateResetScope,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> MLPipelineManifest {
        let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int
        guard let version else {
            throw MLDerivedStateCompatibilityError.resetRequired(
                scope: scope,
                storedSchemaVersion: 0,
                supportedSchemaVersion: supportedSchemaVersion
            )
        }
        guard version == supportedSchemaVersion else {
            throw MLDerivedStateCompatibilityError.resetRequired(
                scope: scope,
                storedSchemaVersion: version,
                supportedSchemaVersion: supportedSchemaVersion
            )
        }
        return try decoder.decode(Self.self, from: data)
    }
}

/// Registry used by the scheduler to activate only pipelines whose feature gate is available.
public struct MLPipelineRegistry: Sendable {
    public let definitions: [MLPipelineDefinition]

    public init(_ definitions: [MLPipelineDefinition]) {
        var seen: Set<MLPipelineID> = []
        self.definitions = definitions.filter { seen.insert($0.id).inserted }
    }

    public func validate(models: MLModelCatalog) throws {
        try validate(models: models, nativeCapabilities: nil)
    }

    public func validate(
        models: MLModelCatalog,
        nativeCapabilities: MLNativeAnalysisCapabilitySnapshot?
    ) throws {
        for definition in definitions {
            for stage in definition.stages {
                switch stage.provider {
                case .model(let modelID, let role):
                    guard let model = models.entry(for: modelID) else {
                        throw MLPipelineRegistryError.missingModel(modelID)
                    }
                    guard let requiredCapability = stage.operation.requiredCapability,
                        model.capabilities.contains(requiredCapability),
                        stage.operation.accepts(role: role)
                    else {
                        throw MLPipelineRegistryError.incompatibleModel(modelID, stage.id)
                    }
                    if let dimension = stage.output?.embeddingDimension,
                        dimension != model.descriptor.embeddingDimension
                    {
                        throw MLPipelineRegistryError.dimensionMismatch(
                            modelID,
                            stage.id,
                            expected: model.descriptor.embeddingDimension,
                            actual: dimension
                        )
                    }
                case .native(let kind, let identifier, let revision):
                    guard let capability = nativeCapabilities?.capability(for: kind),
                        capability.isAvailable
                    else {
                        throw MLPipelineRegistryError.missingNativeCapability(kind, stage.id)
                    }
                    guard capability.implementationIdentifier == identifier,
                        capability.selectedRevision == revision
                    else {
                        throw MLPipelineRegistryError.nativeRevisionMismatch(kind, stage.id)
                    }
                }
            }
        }
    }

    public func activeDefinitions(
        policy: AppFeaturePolicy,
        device: AppDeviceCapabilities,
        tier: AppProductTier
    ) -> [MLPipelineDefinition] {
        definitions.filter { policy.availability(of: $0.feature, device: device, tier: tier) == .available }
    }
}

private extension MLStageOperation {
    var requiredCapability: MLModelCapability? {
        switch self {
        case .imageEmbedding: .imageEmbedding
        case .textEmbedding: .textEmbedding
        case .regionDetection: .regionDetection
        case .regionEmbedding: .regionEmbedding
        case .nativeAnalysis: nil
        }
    }

    func accepts(role: MLModelRole) -> Bool {
        switch self {
        case .imageEmbedding: role == .dualEncoder || role == .imageEncoder
        case .textEmbedding: role == .dualEncoder || role == .textEncoder
        case .regionDetection: role == .regionDetector
        case .regionEmbedding: role == .regionEmbedder
        case .nativeAnalysis: false
        }
    }

    func accepts(output: MLAnalysisOutputDescriptor) -> Bool {
        switch (self, output) {
        case (.imageEmbedding, .semanticEmbedding),
            (.textEmbedding, .semanticEmbedding),
            (.regionDetection, .regions),
            (.regionEmbedding, .regionEmbedding):
            true
        case (.nativeAnalysis(let kind), _):
            kind.accepts(output: output)
        default:
            false
        }
    }
}

private extension MLNativeAnalysisKind {
    func accepts(output: MLAnalysisOutputDescriptor) -> Bool {
        switch (self, output) {
        case (.textRecognition, .recognizedText): true
        case (.documentRecognition, .structuredDocument): true
        case (.barcodeDetection, .barcodePayload): true
        case (.imageClassification, .classifications): true
        case (.imageFeaturePrint, .featurePrint): true
        case (.animalRecognition, .regions), (.humanDetection, .regions),
            (.faceDetection, .regions), (.faceLandmarks, .regions),
            (.animalBodyPose, .regions), (.humanBodyPose, .regions),
            (.humanHandPose, .regions), (.humanBodyPose3D, .regions):
            true
        case (.faceCaptureQuality, .qualityMetrics), (.imageAesthetics, .qualityMetrics),
            (.lensSmudgeDetection, .qualityMetrics), (.horizon, .qualityMetrics):
            true
        case (.attentionSaliency, .saliency), (.objectnessSaliency, .saliency): true
        case (.foregroundInstanceMask, .mask), (.personInstanceMask, .mask),
            (.personSegmentation, .mask):
            true
        case (.documentSegmentation, .geometry), (.contours, .geometry),
            (.horizon, .geometry), (.rectangles, .geometry),
            (.textRectangles, .geometry):
            true
        default: false
        }
    }
}

public enum MLPipelineRegistryError: Error, Equatable {
    case missingModel(MLModelID)
    case incompatibleModel(MLModelID, MLStageID)
    case dimensionMismatch(MLModelID, MLStageID, expected: Int, actual: Int)
    case missingNativeCapability(MLNativeAnalysisKind, MLStageID)
    case nativeRevisionMismatch(MLNativeAnalysisKind, MLStageID)
}
