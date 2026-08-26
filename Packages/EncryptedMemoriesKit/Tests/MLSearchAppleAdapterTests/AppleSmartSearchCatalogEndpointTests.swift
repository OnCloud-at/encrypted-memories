import Foundation
import MLSearchCore
import Testing

@testable import MLSearchAppleAdapter

@Suite struct AppleSmartSearchCatalogEndpointTests {
    @Test func acceptsAValidatedPreviewDirectory() throws {
        let endpoint = try AppleSmartSearchCatalogEndpoint(
            previewBaseURL: URL(string: "https://preview.example.test/private/models/")!
        )

        #expect(endpoint.channel == .preview)
        #expect(endpoint.artifactBaseURL.absoluteString == "https://preview.example.test/private/models/")
        #expect(endpoint.catalogRootURL.absoluteString == "https://preview.example.test/private/")
        #expect(endpoint.activePairURL.absoluteString == "https://preview.example.test/private/active-pair.json")
        #expect(endpoint.catalogV2SignatureURL.absoluteString == "https://preview.example.test/private/catalog-v2.sig")
    }

    @Test func rejectsUnsafePreviewURLs() {
        let values = [
            "http://preview.example.test/models/",
            "https://user:password@preview.example.test/models/",
            "https://preview.example.test/models/?token=redacted",
            "https://preview.example.test/models/#fragment",
            "https://preview.example.test/model/",
            "https:///models/",
        ]

        for value in values {
            #expect(
                throws: AppleSmartSearchCatalogEndpointError.invalidPreviewBaseURL
            ) {
                _ = try AppleSmartSearchCatalogEndpoint(previewBaseURL: URL(string: value)!)
            }
        }
    }

    @Test func resolvesAnInjectedDebugEnvironmentWithoutProcessDefaults() {
        let key = AppleSmartSearchCatalogEndpoint.previewEnvironmentKey
        let preview = AppleSmartSearchCatalogEndpoint.debugEndpoint(
            environment: [key: "https://preview.example.test/models/"]
        )
        let absent = AppleSmartSearchCatalogEndpoint.debugEndpoint(environment: [:])
        let invalid = AppleSmartSearchCatalogEndpoint.debugEndpoint(
            environment: [key: "https://preview.example.test/not-models/"]
        )

        #expect(preview.channel == .preview)
        #expect(absent == .production)
        #expect(invalid == .production)
    }

    @Test func keepsPreviewStorageSeparateFromProductionStorage() throws {
        let account = URL(fileURLWithPath: "/tmp/account", isDirectory: true)
        let preview = try AppleSmartSearchCatalogEndpoint(
            previewBaseURL: URL(string: "https://preview.example.test/models/")!
        )

        let productionRoot = AppleSmartSearchBootstrap.smartSearchRoot(accountDirectory: account)
        let previewRoot = AppleSmartSearchBootstrap.smartSearchRoot(
            accountDirectory: account,
            endpoint: preview
        )
        let productionCache = AppleSmartSearchBootstrap.catalogCacheDirectory(accountDirectory: account)
        let previewCache = AppleSmartSearchBootstrap.catalogCacheDirectory(
            accountDirectory: account,
            endpoint: preview
        )

        #expect(productionRoot.lastPathComponent == "SmartSearch")
        #expect(previewRoot.lastPathComponent == "SmartSearch-MLPreview")
        #expect(productionCache.lastPathComponent == "MLModelCatalog")
        #expect(previewCache.lastPathComponent == "MLModelCatalog-MLPreview")
        #expect(productionRoot != previewRoot)
        #expect(productionCache != previewCache)
    }

    @Test func normalCatalogFilteringHidesDeveloperOnlyEntries() {
        let previewEntry = MLModelCatalogEntry.sigLIP2Base256.withReleaseTrack(.developerOnly)
        let catalog = MLModelCatalog(entries: [previewEntry])

        #expect(catalog.selectableEntries(allowsDeveloperModels: false).isEmpty)
        #expect(catalog.selectableEntries(allowsDeveloperModels: true).map(\.id) == [previewEntry.id])
    }
}
