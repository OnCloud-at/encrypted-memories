import Foundation

/// A finite, app-shipped runtime recipe for a compatible model family.
///
/// Remote catalogs may select a recipe and provide immutable distribution data. They may not
/// introduce a tokenizer, preprocessing path, runtime shape, capability, or native feature.
public struct MLModelCompatibilityRecipe: Sendable, Equatable {
    public let key: String
    public let family: String
    public let role: MLModelRole
    public let capabilities: Set<MLModelCapability>
    public let tokenizerID: String
    public let preprocessingID: String
    public let runtimeContract: MLModelRuntimeContract
    public let embeddingDimension: Int
    public let descriptorVersionRange: ClosedRange<Int>
    public let runtimeResourcePaths: [String]
    public let license: MLModelLicense
    public let maximumArtifactBytes: Int64
    public let maximumArtifactFileBytes: Int64
    public let relevancePolicy: MLSemanticRelevancePolicy
    public let localizedMetadata: MLModelLocalizedMetadata
    public let estimatedInstalledBytes: Int64
    public let releaseTrack: MLModelReleaseTrack

    public init(
        key: String,
        family: String,
        role: MLModelRole,
        capabilities: Set<MLModelCapability>,
        tokenizerID: String,
        preprocessingID: String,
        runtimeContract: MLModelRuntimeContract,
        embeddingDimension: Int,
        descriptorVersionRange: ClosedRange<Int> = 1...1,
        runtimeResourcePaths: [String] = [],
        license: MLModelLicense,
        maximumArtifactBytes: Int64,
        maximumArtifactFileBytes: Int64? = nil,
        relevancePolicy: MLSemanticRelevancePolicy,
        localizedMetadata: MLModelLocalizedMetadata,
        estimatedInstalledBytes: Int64,
        releaseTrack: MLModelReleaseTrack = .production
    ) {
        self.key = key
        self.family = family
        self.role = role
        self.capabilities = capabilities
        self.tokenizerID = tokenizerID
        self.preprocessingID = preprocessingID
        self.runtimeContract = runtimeContract
        self.embeddingDimension = embeddingDimension
        self.descriptorVersionRange = descriptorVersionRange
        self.runtimeResourcePaths = runtimeResourcePaths
        self.license = license
        self.maximumArtifactBytes = maximumArtifactBytes
        self.maximumArtifactFileBytes = maximumArtifactFileBytes ?? maximumArtifactBytes
        self.relevancePolicy = relevancePolicy
        self.localizedMetadata = localizedMetadata
        self.estimatedInstalledBytes = estimatedInstalledBytes
        self.releaseTrack = releaseTrack
    }

    public func accepts(descriptor: MLModelDescriptor) -> Bool {
        descriptor.version >= descriptorVersionRange.lowerBound
            && descriptor.version <= descriptorVersionRange.upperBound
            && descriptor.embeddingDimension == embeddingDimension
    }
}

/// The only model runtime recipes that this app can activate without another app update.
public struct MLModelCompatibilityRegistry: Sendable, Equatable {
    public let recipes: [String: MLModelCompatibilityRecipe]

    public init(recipes: [MLModelCompatibilityRecipe]) {
        var unique: [String: MLModelCompatibilityRecipe] = [:]
        for recipe in recipes where !recipe.key.isEmpty {
            unique[recipe.key] = recipe
        }
        self.recipes = unique
    }

    public func recipe(for key: String) -> MLModelCompatibilityRecipe? {
        recipes[key]
    }

    public static let builtIn = MLModelCompatibilityRegistry(recipes: [
        MLModelCompatibilityRecipe(
            key: "clip-dual-encoder-v1",
            family: "TinyCLIP",
            role: .dualEncoder,
            capabilities: [.imageEmbedding, .textEmbedding],
            tokenizerID: "clip-bpe-77",
            preprocessingID: "clip-centercrop-224",
            runtimeContract: .clipDualEncoder(imagePixelSide: 224),
            embeddingDimension: 512,
            descriptorVersionRange: 1...65_535,
            license: .mit,
            maximumArtifactBytes: 220_000_000,
            relevancePolicy: .init(
                minimumBestScore: 0.23,
                minimumResultScore: 0.20,
                relativeScoreFloor: 0.72
            ),
            localizedMetadata: .init(
                selectionTitleKey: "mlsearch.model_tinyclip_title",
                selectionDescriptionKey: "mlsearch.model_tinyclip_description"
            ),
            estimatedInstalledBytes: 130_000_000
        ),
        MLModelCompatibilityRecipe(
            key: "siglip-dual-encoder-v1",
            family: "SigLIP2",
            role: .dualEncoder,
            capabilities: [.imageEmbedding, .textEmbedding],
            tokenizerID: "gemma-sentencepiece-64",
            preprocessingID: "siglip-resize-256",
            runtimeContract: .siglipDualEncoder(imagePixelSide: 256),
            embeddingDimension: 768,
            descriptorVersionRange: 1...65_535,
            runtimeResourcePaths: ["tokenizer.json"],
            license: .apache2,
            maximumArtifactBytes: 900_000_000,
            relevancePolicy: .init(
                minimumBestScore: 0.065,
                minimumResultScore: 0.060,
                relativeScoreFloor: 0.55
            ),
            localizedMetadata: .init(
                selectionTitleKey: "mlsearch.model_siglip2_title",
                selectionDescriptionKey: "mlsearch.model_siglip2_description"
            ),
            estimatedInstalledBytes: 760_000_000
        ),
    ])
}
