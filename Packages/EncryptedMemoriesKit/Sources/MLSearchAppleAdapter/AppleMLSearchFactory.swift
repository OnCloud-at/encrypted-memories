import Foundation
import MLSearchCore
import MediaFeedCore
import PhotosCore

public enum AppleMLSearchFactoryError: Error {
    case indexStoreUnavailable
}

/// Single composition point for the Apple ML stack used by macOS, iOS and iPadOS.
public enum AppleMLSearchFactory {
    public static func makeTinyCLIPService(
        modelURL: URL,
        descriptor: MLModelDescriptor,
        indexURL: URL,
        accountUID: String,
        keyPassword: String,
        feed: ThumbnailFeedCore,
        relevancePolicy: MLSemanticRelevancePolicy = MLModelCatalogEntry.tinyCLIPVit40M.relevancePolicy,
        databasePolicy: LibraryDatabasePolicy = .conservative,
        runnerConfiguration: MLIndexRunner.Configuration = .init(),
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async throws -> MLSearchService {
        let cipher = CryptoKitMLVectorCipher(
            key: MLSearchKeyDerivation.localIndexKey(accountUID: accountUID, keyPassword: keyPassword),
            accountUID: accountUID
        )
        guard let store = SQLiteMLIndexStore(url: indexURL, policy: databasePolicy, cipher: cipher) else {
            throw AppleMLSearchFactoryError.indexStoreUnavailable
        }
        let encoder = try await CoreMLDualEncoder(
            modelURL: modelURL,
            descriptor: descriptor,
            imageSource: CachedThumbnailMLImageSource(feed: feed),
            tokenizer: CLIPBPETokenizer.bundledTinyCLIP()
        )
        return MLSearchService(
            descriptor: descriptor,
            store: store,
            assetEmbedder: encoder,
            textEncoder: encoder,
            scorer: AccelerateVectorScorer(),
            relevancePolicy: relevancePolicy,
            runnerConfiguration: runnerConfiguration,
            shouldContinue: shouldContinue,
            releaseInferenceResources: { await encoder.releaseModel() }
        )
    }
}
