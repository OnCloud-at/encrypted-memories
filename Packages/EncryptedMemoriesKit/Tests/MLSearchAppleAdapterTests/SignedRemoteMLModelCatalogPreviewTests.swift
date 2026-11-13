import CryptoKit
import Foundation
import MLSearchCore
import Testing

@testable import MLSearchAppleAdapter

@Suite(.serialized) struct SignedRemoteMLModelCatalogPreviewTests {
    private struct PointerObject: Codable {
        let name: String
        let path: String
        let sha256: String
        let bytes: Int64
    }

    private struct PointerPayload: Codable {
        let schemaVersion: Int
        let pairID: String
        let catalogSequence: UInt64
        let objects: [PointerObject]
    }

    private struct Pointer: Codable {
        let payload: PointerPayload
        let signature: String
    }

    private final class StubProtocol: CatalogStubProtocol, @unchecked Sendable {}

    @Test func previewForcesEveryResolvedEntryToDeveloperOnly() async throws {
        let endpoint = try AppleSmartSearchCatalogEndpoint(
            previewBaseURL: URL(string: "https://preview.example.test/models/")!
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-preview-provider-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let id = MLModelCatalogEntry.tinyCLIPVit40M.id
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let artifact = MLRemoteModelCatalogDocument.Artifact(
            path: "TinyCLIP.mlmodelc/weights.bin",
            url: endpoint.artifactBaseURL.appendingPathComponent(
                "\(id.rawValue)/revision-1/TinyCLIP.mlmodelc/weights.bin"
            ),
            sha256: String(repeating: "a", count: 64),
            bytes: 1
        )
        let catalogV1 = try encoder.encode(MLRemoteModelCatalogDocument(models: []))
        let catalogV2 = try encoder.encode(
            MLRemoteModelCatalogDocumentV2(
                catalogSequence: 1,
                models: [
                    .init(
                        id: id,
                        compatibilityKey: "clip-dual-encoder-v1",
                        releaseSequence: 1,
                        revision: "revision-1",
                        descriptor: .init(identifier: id.rawValue, version: 1, embeddingDimension: 512),
                        sourceRevision: String(repeating: "b", count: 40),
                        licenseIdentifier: "MIT",
                        role: "dualEncoder",
                        capabilities: ["imageEmbedding", "textEmbedding"],
                        artifacts: [artifact]
                    )
                ]
            )
        )
        let signatureV1 = try key.signature(for: catalogV1)
        let signatureV2 = try key.signature(for: catalogV2)
        let pairManifest = Data("preview-pair".utf8)
        let pairID = Self.sha256(pairManifest)
        let objectsData: [(String, Data)] = [
            ("catalog-v1.json", catalogV1),
            ("catalog-v1.sig", signatureV1),
            ("catalog-v2.json", catalogV2),
            ("catalog-v2.sig", signatureV2),
            ("release-pair.json", pairManifest),
        ]
        let objects = objectsData.map { name, data in
            PointerObject(
                name: name,
                path: "catalog-history/\(pairID)/\(name)",
                sha256: Self.sha256(data),
                bytes: Int64(data.count)
            )
        }
        let payload = PointerPayload(
            schemaVersion: 1,
            pairID: pairID,
            catalogSequence: 1,
            objects: objects
        )
        let payloadData = try encoder.encode(payload)
        let pointerData = try encoder.encode(
            Pointer(payload: payload, signature: key.signature(for: payloadData).base64EncodedString())
        )
        var responses: [URL: Data] = [endpoint.activePairURL: pointerData]
        for (name, data) in objectsData {
            responses[endpoint.catalogRootURL.appendingPathComponent("catalog-history/\(pairID)/\(name)")] = data
        }
        StubProtocol.configure(responses: responses)
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            endpoint: endpoint,
            session: catalogStubSession(for: StubProtocol.self),
            publicKey: key.publicKey.rawRepresentation
        )

        let resolved = try await provider.catalog()
        let previewEntry = try #require(resolved.entry(for: id))
        #expect(previewEntry.releaseTrack == .developerOnly)
        #expect(resolved.selectableEntries(allowsDeveloperModels: false).contains { $0.id == id } == false)
        #expect(resolved.selectableEntries(allowsDeveloperModels: true).contains { $0.id == id })
    }

    @Test func previewDoesNotFallBackToPublicLegacyV1() async throws {
        let endpoint = try AppleSmartSearchCatalogEndpoint(
            previewBaseURL: URL(string: "https://preview.example.test/models/")!
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-preview-no-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        StubProtocol.configure(responses: [endpoint.activePairURL: Data("invalid".utf8)])
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            endpoint: endpoint,
            session: catalogStubSession(for: StubProtocol.self)
        )

        await #expect(throws: (any Error).self) {
            _ = try await provider.catalog()
        }
        #expect(
            StubProtocol.recordedRequests.allSatisfy {
                $0.url?.host != SignedRemoteMLModelCatalogProvider.catalogURL.host
            }
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
