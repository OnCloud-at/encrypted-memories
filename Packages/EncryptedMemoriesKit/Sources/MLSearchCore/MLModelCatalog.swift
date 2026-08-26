import Foundation

/// Stable identity of a Smart Search model in the catalog. Distinct from
/// `MLModelDescriptor.identifier` only in role: the catalog ID names the *product entry* a user
/// can select; the descriptor names the *embedding epoch* the entry currently produces.
public struct MLModelID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// License classification the UI must surface before a model can be selected.
public struct MLModelLicense: Sendable, Hashable, Codable {
    /// SPDX-style identifier (`"MIT"`) or a stable custom marker (`"Apple-AMLR"`).
    public let identifier: String
    /// `true` only when the weights may legally ship to end users.
    public let allowsRedistribution: Bool
    /// `true` only when the weights may be used in a commercial product.
    public let allowsProductUse: Bool

    public init(identifier: String, allowsRedistribution: Bool, allowsProductUse: Bool) {
        self.identifier = identifier
        self.allowsRedistribution = allowsRedistribution
        self.allowsProductUse = allowsProductUse
    }

    public static let mit = MLModelLicense(identifier: "MIT", allowsRedistribution: true, allowsProductUse: true)
    public static let apache2 = MLModelLicense(
        identifier: "Apache-2.0", allowsRedistribution: true, allowsProductUse: true)
}

/// Release track of a catalog entry. Developer-only entries are selectable exclusively in
/// environments that explicitly allow them (never in Release builds).
public enum MLModelReleaseTrack: String, Sendable, Hashable, Codable {
    case production
    case developerOnly
}

/// Capabilities are declared by the trusted app catalog. Pipeline stages can therefore validate
/// model compatibility without family-name switches or platform-specific code.
public enum MLModelCapability: String, Hashable, Sendable, Codable {
    case imageEmbedding
    case textEmbedding
    case regionDetection
    case regionEmbedding
}

/// Localization keys for the model explanation shown by every platform.
///
/// The remote catalog controls availability and exact artifact sizes, never product copy. That
/// keeps descriptions reviewable in the app's string catalog and prevents server content from
/// becoming an unreviewed UI surface.
public struct MLModelLocalizedMetadata: Sendable, Equatable {
    public let selectionTitleKey: String
    public let selectionDescriptionKey: String

    public init(selectionTitleKey: String, selectionDescriptionKey: String) {
        self.selectionTitleKey = selectionTitleKey
        self.selectionDescriptionKey = selectionDescriptionKey
    }
}

/// Optional evidence that one immutable artifact revision passed an external on-device release run.
/// It is informational metadata, never a runtime availability gate.
public struct MLModelReleaseQualification: Sendable, Equatable, Codable {
    public let artifactRevision: String
    public let hardwareModel: String
    public let osVersion: String
    public let peakResidentBytes: Int64
    public let imageP95Milliseconds: Double
    public let textP95Milliseconds: Double
    public let reachedSeriousThermalState: Bool
    public let neuralEngineExecutionVerified: Bool
    public let passed: Bool

    public init(
        artifactRevision: String,
        hardwareModel: String,
        osVersion: String,
        peakResidentBytes: Int64,
        imageP95Milliseconds: Double,
        textP95Milliseconds: Double,
        reachedSeriousThermalState: Bool,
        neuralEngineExecutionVerified: Bool,
        passed: Bool
    ) {
        self.artifactRevision = artifactRevision
        self.hardwareModel = hardwareModel
        self.osVersion = osVersion
        self.peakResidentBytes = peakResidentBytes
        self.imageP95Milliseconds = imageP95Milliseconds
        self.textP95Milliseconds = textP95Milliseconds
        self.reachedSeriousThermalState = reachedSeriousThermalState
        self.neuralEngineExecutionVerified = neuralEngineExecutionVerified
        self.passed = passed
    }
}

/// One file of a model installation, identified by its install-relative path and content hash.
///
/// `relativePath` is validated against path traversal before any filesystem use; see
/// `MLModelInstallLayout.isSafeRelativePath`.
public struct MLModelArtifactSpec: Sendable, Hashable, Codable {
    public let relativePath: String
    /// Lowercase hex SHA-256 of the artifact file content.
    public let sha256: String
    /// Expected byte size of the artifact file; verified before activation.
    public let byteCount: Int64

    public init(relativePath: String, sha256: String, byteCount: Int64) {
        self.relativePath = relativePath
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
    }
}

/// Immutable description of a downloadable model revision.
///
/// The plan pins exact content: an immutable revision token (e.g. a Hugging Face commit hash or
/// a CDN release tag), one URL per artifact, and the SHA-256 each download must match. A plan
/// referencing a mutable branch is a configuration bug; revisions must be commit-pinned.
public struct MLModelDownloadPlan: Sendable, Equatable, Codable {
    public struct Item: Sendable, Equatable, Codable {
        public let url: URL
        public let artifact: MLModelArtifactSpec

        public init(url: URL, artifact: MLModelArtifactSpec) {
            self.url = url
            self.artifact = artifact
        }
    }

    /// Immutable revision token identifying this exact artifact set.
    public let revision: String
    public let items: [Item]

    public init(revision: String, items: [Item]) {
        self.revision = revision
        self.items = items
    }

    public var totalByteCount: Int64 { items.reduce(0) { $0 + $1.artifact.byteCount } }
}

/// Catalog-bound CoreML runtime contract: the exact function names, feature names, text
/// context length and image input size a model artifact must expose. The adapter validates a
/// loaded artifact against this contract before any session activates; a mismatching artifact
/// is a `modelLoad` failure, never undefined inference. Data, not code: new CLIP-family models
/// ship as catalog entries with their own contract values, without per-model runtime branches.
public struct MLModelRuntimeContract: Sendable, Hashable, Codable {
    /// Multi-function model: function computing image embeddings.
    public var imageFunctionName: String
    /// Multi-function model: function computing text embeddings.
    public var textFunctionName: String
    public var imageInputName: String
    public var tokenInputName: String
    /// End-of-text mask input, or `nil` for families whose text tower pools internally
    /// (SigLIP-style: fixed-length padded ids are the only text input).
    public var endTokenMaskInputName: String?
    public var embeddingOutputName: String
    /// Fixed token count of the text encoder input; the tokenizer must produce exactly this.
    public var textContextLength: Int
    /// Square input side (pixels) the image encoder expects; the artifact's image constraint
    /// must match exactly (preprocessing recipe identity lives in `preprocessingID`).
    public var imagePixelSide: Int

    public init(
        imageFunctionName: String,
        textFunctionName: String,
        imageInputName: String,
        tokenInputName: String,
        endTokenMaskInputName: String?,
        embeddingOutputName: String,
        textContextLength: Int,
        imagePixelSide: Int
    ) {
        self.imageFunctionName = imageFunctionName
        self.textFunctionName = textFunctionName
        self.imageInputName = imageInputName
        self.tokenInputName = tokenInputName
        self.endTokenMaskInputName = endTokenMaskInputName
        self.embeddingOutputName = embeddingOutputName
        self.textContextLength = textContextLength
        self.imagePixelSide = imagePixelSide
    }

    /// The CLIP dual-encoder convention our converted artifacts follow (77-token context).
    public static func clipDualEncoder(imagePixelSide: Int) -> MLModelRuntimeContract {
        MLModelRuntimeContract(
            imageFunctionName: "image",
            textFunctionName: "text",
            imageInputName: "image",
            tokenInputName: "input_ids",
            endTokenMaskInputName: "eot_mask",
            embeddingOutputName: "embedding",
            textContextLength: 77,
            imagePixelSide: imagePixelSide
        )
    }

    /// The SigLIP dual-encoder convention: fixed-length padded ids, internal pooling
    /// (no mask input), 64-token context.
    public static func siglipDualEncoder(imagePixelSide: Int) -> MLModelRuntimeContract {
        MLModelRuntimeContract(
            imageFunctionName: "image",
            textFunctionName: "text",
            imageInputName: "image",
            tokenInputName: "input_ids",
            endTokenMaskInputName: nil,
            embeddingOutputName: "embedding",
            textContextLength: 64,
            imagePixelSide: imagePixelSide
        )
    }
}

/// One selectable Smart Search model. Immutable: changing any compatibility-relevant property
/// (tokenizer, preprocessing, weights revision, dimension) requires bumping the descriptor
/// version, which retires every existing embedding for the old epoch deterministically.
public struct MLModelCatalogEntry: Sendable, Equatable, Identifiable {
    public let id: MLModelID
    /// The finite compatibility recipe used by updated clients, when this entry came from one.
    public let compatibilityKey: String?
    /// The model role is part of the compiled runtime contract.
    public let role: MLModelRole
    /// Display-safe product name (localized display goes through the presentation layer).
    public let displayName: String
    /// Model family marker for diagnostics (`"TinyCLIP"`, `"SigLIP2"`).
    public let family: String
    public let capabilities: Set<MLModelCapability>
    /// Immutable upstream weights revision used to produce the artifact, when applicable.
    public let sourceRevision: String?
    /// The embedding epoch this entry currently produces. `descriptor.version` is the single
    /// invalidation knob: bump it whenever tokenizer/preprocessing/weights change compatibility.
    public let descriptor: MLModelDescriptor
    /// Stable tokenizer identity; sessions must refuse to start when the runtime tokenizer
    /// doesn't match.
    public let tokenizerID: String
    /// Stable preprocessing identity (resize/crop/normalization recipe).
    public let preprocessingID: String
    /// CoreML runtime contract the installed artifact must satisfy before activation.
    public let runtimeContract: MLModelRuntimeContract
    /// Model-specific score calibration that removes irrelevant nearest-neighbour tails.
    public let relevancePolicy: MLSemanticRelevancePolicy
    /// Install-root files required beside the model. Local installs copy only these declared
    /// sidecars, so conversion work products cannot silently inflate the installed footprint.
    public let runtimeResourcePaths: [String]
    public let license: MLModelLicense
    public let releaseTrack: MLModelReleaseTrack
    public let localizedMetadata: MLModelLocalizedMetadata
    /// Approximate installed size for UI, before an installation exists. Actual installed
    /// size is measured after install.
    public let estimatedInstalledBytes: Int64
    /// Pinned download plan, or `nil` when no immutable hosted artifact exists yet. A `nil`
    /// plan means the model can only be installed from a developer-provided local artifact.
    public let downloadPlan: MLModelDownloadPlan?
    /// Optional on-device evidence for the exact hosted revision. When supplied, stale or failed
    /// evidence keeps the entry out of Release.
    public let releaseQualification: MLModelReleaseQualification?

    public init(
        id: MLModelID,
        compatibilityKey: String? = nil,
        displayName: String,
        family: String,
        role: MLModelRole = .dualEncoder,
        capabilities: Set<MLModelCapability> = [.imageEmbedding, .textEmbedding],
        sourceRevision: String? = nil,
        descriptor: MLModelDescriptor,
        tokenizerID: String,
        preprocessingID: String,
        runtimeContract: MLModelRuntimeContract = .clipDualEncoder(imagePixelSide: 224),
        relevancePolicy: MLSemanticRelevancePolicy = .unfiltered,
        runtimeResourcePaths: [String] = [],
        license: MLModelLicense,
        releaseTrack: MLModelReleaseTrack,
        localizedMetadata: MLModelLocalizedMetadata = .init(
            selectionTitleKey: "mlsearch.model_generic_title",
            selectionDescriptionKey: "mlsearch.model_generic_description"
        ),
        estimatedInstalledBytes: Int64,
        downloadPlan: MLModelDownloadPlan?,
        releaseQualification: MLModelReleaseQualification? = nil
    ) {
        self.id = id
        self.compatibilityKey = compatibilityKey
        self.role = role
        self.displayName = displayName
        self.family = family
        self.capabilities = capabilities
        self.sourceRevision = sourceRevision
        self.descriptor = descriptor
        self.tokenizerID = tokenizerID
        self.preprocessingID = preprocessingID
        self.runtimeContract = runtimeContract
        self.relevancePolicy = relevancePolicy
        self.runtimeResourcePaths = runtimeResourcePaths
        self.license = license
        self.releaseTrack = releaseTrack
        self.localizedMetadata = localizedMetadata
        self.estimatedInstalledBytes = estimatedInstalledBytes
        self.downloadPlan = downloadPlan
        self.releaseQualification = releaseQualification
    }

    /// A model is downloadable only with a pinned plan AND a license that permits both
    /// redistributing the weights to end users and using them in the product. A plan on a
    /// restrictively licensed entry is a configuration bug and stays technically inert.
    /// Developer-only models install from local artifacts instead.
    public var isDownloadable: Bool {
        downloadPlan != nil && license.allowsRedistribution && license.allowsProductUse
    }

    /// Release builds expose only legally distributable production entries backed by an
    /// immutable download plan. Optional qualification metadata never changes availability.
    public var isReleaseReady: Bool {
        releaseTrack == .production && isDownloadable
    }

    /// Apply signed distribution and qualification metadata to an app-reviewed model contract.
    /// Remote data can never replace tokenizer, preprocessing, runtime, license, or release policy.
    public func withDistribution(
        _ plan: MLModelDownloadPlan?,
        qualification: MLModelReleaseQualification?
    ) -> MLModelCatalogEntry {
        MLModelCatalogEntry(
            id: id,
            compatibilityKey: compatibilityKey,
            displayName: displayName,
            family: family,
            role: role,
            capabilities: capabilities,
            sourceRevision: sourceRevision,
            descriptor: descriptor,
            tokenizerID: tokenizerID,
            preprocessingID: preprocessingID,
            runtimeContract: runtimeContract,
            relevancePolicy: relevancePolicy,
            runtimeResourcePaths: runtimeResourcePaths,
            license: license,
            releaseTrack: releaseTrack,
            localizedMetadata: localizedMetadata,
            estimatedInstalledBytes: estimatedInstalledBytes,
            downloadPlan: plan,
            releaseQualification: qualification
        )
    }

    /// Change the app-owned release track without changing the remote distribution contract.
    public func withReleaseTrack(_ releaseTrack: MLModelReleaseTrack) -> MLModelCatalogEntry {
        MLModelCatalogEntry(
            id: id,
            compatibilityKey: compatibilityKey,
            displayName: displayName,
            family: family,
            role: role,
            capabilities: capabilities,
            sourceRevision: sourceRevision,
            descriptor: descriptor,
            tokenizerID: tokenizerID,
            preprocessingID: preprocessingID,
            runtimeContract: runtimeContract,
            relevancePolicy: relevancePolicy,
            runtimeResourcePaths: runtimeResourcePaths,
            license: license,
            releaseTrack: releaseTrack,
            localizedMetadata: localizedMetadata,
            estimatedInstalledBytes: estimatedInstalledBytes,
            downloadPlan: downloadPlan,
            releaseQualification: releaseQualification
        )
    }
}

/// The immutable set of models this build can offer.
///
/// Hosts filter by environment (`allowsDeveloperModels`) before showing entries. The catalog is
/// data, not policy: enable/select/install decisions belong to `MLSmartSearchLifecycle`.
public struct MLModelCatalog: Sendable, Equatable {
    public let entries: [MLModelCatalogEntry]

    public init(entries: [MLModelCatalogEntry]) {
        self.entries = entries
    }

    public func entry(for id: MLModelID) -> MLModelCatalogEntry? {
        entries.first { $0.id == id }
    }

    /// Entries this environment may select. Release builds require a signed immutable download
    /// plan, production track and a license permitting product use. Developer environments
    /// additionally see local-artifact entries.
    public func selectableEntries(allowsDeveloperModels: Bool) -> [MLModelCatalogEntry] {
        allowsDeveloperModels
            ? entries
            : entries.filter(\.isReleaseReady)
    }
}

extension MLModelCatalogEntry {
    /// TinyCLIP production entry for the CLIP dual-encoder runtime contract.
    /// The signed catalog supplies the immutable Core ML artifact.
    public static let tinyCLIPVit40M = MLModelCatalogEntry(
        id: MLModelID("tinyclip-vit-40m-32-text-19m"),
        compatibilityKey: "clip-dual-encoder-v1",
        displayName: "TinyCLIP 40M",
        family: "TinyCLIP",
        sourceRevision: "95ec8197b3f2fe7f747865c61ca556cf0768b2f7",
        descriptor: MLModelDescriptor(identifier: "tinyclip-vit-40m-32-text-19m", version: 1, embeddingDimension: 512),
        tokenizerID: "clip-bpe-77",
        preprocessingID: "clip-centercrop-224",
        runtimeContract: .clipDualEncoder(imagePixelSide: 224),
        // These thresholds remove low-confidence matches from the shipped model output.
        relevancePolicy: .init(
            minimumBestScore: 0.23,
            minimumResultScore: 0.20,
            relativeScoreFloor: 0.72
        ),
        license: .mit,
        releaseTrack: .production,
        localizedMetadata: .init(
            selectionTitleKey: "mlsearch.model_tinyclip_title",
            selectionDescriptionKey: "mlsearch.model_tinyclip_description"
        ),
        estimatedInstalledBytes: 130_000_000,
        downloadPlan: nil
    )

    /// SigLIP2 production entry for multilingual image and text embeddings.
    /// The signed catalog supplies the immutable Core ML artifact and tokenizer.
    public static let sigLIP2Base256 = MLModelCatalogEntry(
        id: MLModelID("siglip2-base-patch16-256"),
        compatibilityKey: "siglip-dual-encoder-v1",
        displayName: "SigLIP 2",
        family: "SigLIP2",
        sourceRevision: "3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab",
        descriptor: MLModelDescriptor(identifier: "siglip2-base-patch16-256", version: 1, embeddingDimension: 768),
        tokenizerID: "gemma-sentencepiece-64",
        preprocessingID: "siglip-resize-256",
        runtimeContract: .siglipDualEncoder(imagePixelSide: 256),
        // These thresholds remove low-confidence matches from the shipped model output.
        relevancePolicy: .init(
            minimumBestScore: 0.065,
            minimumResultScore: 0.060,
            relativeScoreFloor: 0.55
        ),
        runtimeResourcePaths: ["tokenizer.json"],
        license: .apache2,
        releaseTrack: .production,
        localizedMetadata: .init(
            selectionTitleKey: "mlsearch.model_siglip2_title",
            selectionDescriptionKey: "mlsearch.model_siglip2_description"
        ),
        estimatedInstalledBytes: 760_000_000,
        downloadPlan: nil
    )
}

extension MLModelCatalog {
    public static let builtIn = MLModelCatalog(entries: [
        .sigLIP2Base256,
        .tinyCLIPVit40M,
    ])
}
