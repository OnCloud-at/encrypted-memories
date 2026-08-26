import CryptoKit
import Foundation
import MLSearchCore
import Testing

@testable import MLSearchAppleAdapter

private struct TestActivePointerObject: Codable {
    let name: String
    let path: String
    let sha256: String
    let bytes: Int
}

private struct TestActivePointerPayload: Codable {
    let schemaVersion: Int
    let pairID: String
    let catalogSequence: Int
    let objects: [TestActivePointerObject]
}

@Suite(.serialized) struct SignedRemoteMLModelCatalogProviderTests {
    private final class StubProtocol: URLProtocol {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var responses: [URL: Data] = [:]
        nonisolated(unsafe) private static var requests: [URLRequest] = []

        static func configure(responses: [URL: Data]) {
            lock.withLock {
                self.responses = responses
                requests = []
            }
        }

        static func replaceResponse(_ data: Data, for url: URL) {
            lock.withLock { responses[url] = data }
        }

        static var recordedRequests: [URLRequest] { lock.withLock { requests } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let data = Self.lock.withLock { () -> Data? in
                Self.requests.append(request)
                guard let url = request.url else { return nil }
                return Self.responses[url]
            }
            guard let data, let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": String(data.count)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test func verifiesSignatureResolvesTrustedModelAndFallsBackToVerifiedCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-model-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogURL = URL(string: "https://catalog.test/catalog-v1.json")!
        let signatureURL = URL(string: "https://catalog.test/catalog-v1.sig")!
        let artifactBaseURL = URL(string: "https://catalog.test/models/")!
        let artifactURL = artifactBaseURL.appendingPathComponent("tiny/rev/TinyCLIP.mlmodelc/weights.bin")
        let document = MLRemoteModelCatalogDocument(models: [
            .init(
                id: MLModelCatalogEntry.tinyCLIPVit40M.id, revision: "rev",
                artifacts: [
                    .init(
                        path: "TinyCLIP.mlmodelc/weights.bin",
                        url: artifactURL,
                        sha256: String(repeating: "a", count: 64),
                        bytes: 123
                    )
                ],
                qualification: MLModelReleaseQualification(
                    artifactRevision: "rev",
                    hardwareModel: "oldest-supported-iphone",
                    osVersion: "26.0",
                    peakResidentBytes: 100,
                    imageP95Milliseconds: 10,
                    textP95Milliseconds: 5,
                    reachedSeriousThermalState: false,
                    neuralEngineExecutionVerified: true,
                    passed: true
                ))
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let documentData = try encoder.encode(document)
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: documentData)
        StubProtocol.configure(responses: [
            catalogURL: documentData,
            signatureURL: signature,
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            session: URLSession(configuration: configuration),
            catalogURL: catalogURL,
            signatureURL: signatureURL,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )

        let remote = try await provider.catalog()
        #expect(remote.entry(for: MLModelCatalogEntry.tinyCLIPVit40M.id)?.downloadPlan?.totalByteCount == 123)
        #expect(remote.entry(for: MLModelCatalogEntry.tinyCLIPVit40M.id)?.isReleaseReady == true)
        let requests = StubProtocol.recordedRequests
        #expect(requests.count == 2)
        #expect(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: MLModelRequestIdentity.headerName) == MLModelRequestIdentity.appIdentifier
            })
        // A later bad network response cannot replace the last verified catalog.
        StubProtocol.replaceResponse(Data(repeating: 0, count: 64), for: signatureURL)
        let cached = try await provider.catalog()
        #expect(cached.entry(for: MLModelCatalogEntry.tinyCLIPVit40M.id)?.downloadPlan?.totalByteCount == 123)
    }

    @Test func v2PersistsASequenceFloorAndRejectsRollback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-model-v2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogURL = URL(string: "https://catalog.test/catalog-v2.json")!
        let signatureURL = URL(string: "https://catalog.test/catalog-v2.sig")!
        let artifactBaseURL = URL(string: "https://catalog.test/models/")!
        let key = Curve25519.Signing.PrivateKey()
        let current = try encodedV2(sequence: 10, artifactBaseURL: artifactBaseURL)
        StubProtocol.configure(responses: [
            catalogURL: current.data,
            signatureURL: try key.signature(for: current.data),
        ])
        let session = stubSession()
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            version: .v2,
            session: session,
            catalogURL: catalogURL,
            signatureURL: signatureURL,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )

        _ = try await provider.catalog()
        try FileManager.default.removeItem(at: root.appendingPathComponent("catalog-v2.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("catalog-v2.sig"))
        let stale = try encodedV2(sequence: 9, artifactBaseURL: artifactBaseURL)
        StubProtocol.configure(responses: [
            catalogURL: stale.data,
            signatureURL: try key.signature(for: stale.data),
        ])
        let restarted = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            version: .v2,
            session: session,
            catalogURL: catalogURL,
            signatureURL: signatureURL,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )

        await #expect(throws: MLRemoteCatalogTransportError.catalogRollback(accepted: 10, received: 9)) {
            _ = try await restarted.catalog()
        }
    }

    @Test func v2RejectsAnOlderModelReleaseInsideANewerCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-model-release-floor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogURL = URL(string: "https://catalog.test/catalog-v2.json")!
        let signatureURL = URL(string: "https://catalog.test/catalog-v2.sig")!
        let artifactBaseURL = URL(string: "https://catalog.test/models/")!
        let key = Curve25519.Signing.PrivateKey()
        let current = try encodedV2(
            sequence: 10,
            modelReleaseSequence: 2,
            revision: "revision-2",
            artifactBaseURL: artifactBaseURL
        )
        StubProtocol.configure(responses: [
            catalogURL: current.data,
            signatureURL: try key.signature(for: current.data),
        ])
        let session = stubSession()
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            version: .v2,
            session: session,
            catalogURL: catalogURL,
            signatureURL: signatureURL,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )
        _ = try await provider.catalog()
        try FileManager.default.removeItem(at: root.appendingPathComponent("catalog-v2.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("catalog-v2.sig"))

        let rollback = try encodedV2(
            sequence: 11,
            modelReleaseSequence: 1,
            revision: "revision-1",
            artifactBaseURL: artifactBaseURL
        )
        StubProtocol.configure(responses: [
            catalogURL: rollback.data,
            signatureURL: try key.signature(for: rollback.data),
        ])
        let restarted = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            version: .v2,
            session: session,
            catalogURL: catalogURL,
            signatureURL: signatureURL,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )

        await #expect(
            throws: MLRemoteCatalogTransportError.modelReleaseRollback(
                modelID: MLModelCatalogEntry.tinyCLIPVit40M.id.rawValue,
                accepted: 2,
                received: 1
            )
        ) {
            _ = try await restarted.catalog()
        }
    }

    @Test func v2DoesNotAdvanceSequenceFloorWhenCatalogCacheCannotCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-model-cache-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("catalog-v2.json", isDirectory: true),
            withIntermediateDirectories: false
        )

        let catalogURL = URL(string: "https://catalog.test/catalog-v2.json")!
        let signatureURL = URL(string: "https://catalog.test/catalog-v2.sig")!
        let artifactBaseURL = URL(string: "https://catalog.test/models/")!
        let key = Curve25519.Signing.PrivateKey()
        let current = try encodedV2(sequence: 10, artifactBaseURL: artifactBaseURL)
        StubProtocol.configure(responses: [
            catalogURL: current.data,
            signatureURL: try key.signature(for: current.data),
        ])
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            version: .v2,
            session: stubSession(),
            catalogURL: catalogURL,
            signatureURL: signatureURL,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )

        await #expect(throws: (any Error).self) {
            _ = try await provider.catalog()
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("catalog-v2.accepted.json").path
            ))
    }

    @Test func v2UsesConfiguredV1EndpointAndItsVerifiedCacheBeforeFirstV2Acceptance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-model-v1-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let v2URL = URL(string: "https://catalog.test/catalog-v2.json")!
        let v2SignatureURL = URL(string: "https://catalog.test/catalog-v2.sig")!
        let v1URL = URL(string: "https://legacy.test/catalog-v1.json")!
        let v1SignatureURL = URL(string: "https://legacy.test/catalog-v1.sig")!
        let artifactBaseURL = URL(string: "https://catalog.test/models/")!
        let key = Curve25519.Signing.PrivateKey()
        let legacy = MLRemoteModelCatalogDocument(models: [
            .init(
                id: MLModelCatalogEntry.tinyCLIPVit40M.id, revision: "legacy",
                artifacts: [
                    .init(
                        path: "TinyCLIP.mlmodelc/weights.bin",
                        url: artifactBaseURL.appendingPathComponent("tiny/legacy/TinyCLIP.mlmodelc/weights.bin"),
                        sha256: String(repeating: "a", count: 64),
                        bytes: 12
                    )
                ])
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacyData = try encoder.encode(legacy)
        StubProtocol.configure(responses: [
            v1URL: legacyData,
            v1SignatureURL: try key.signature(for: legacyData),
        ])
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            version: .v2,
            session: stubSession(),
            catalogURL: v2URL,
            signatureURL: v2SignatureURL,
            legacyCatalogURL: v1URL,
            legacySignatureURL: v1SignatureURL,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )

        let online = try await provider.catalog()
        #expect(online.entry(for: MLModelCatalogEntry.tinyCLIPVit40M.id)?.downloadPlan?.totalByteCount == 12)
        #expect(StubProtocol.recordedRequests.contains { $0.url == v1URL })
        StubProtocol.configure(responses: [:])
        let offline = try await provider.catalog()
        #expect(offline.entry(for: MLModelCatalogEntry.tinyCLIPVit40M.id)?.downloadPlan?.totalByteCount == 12)
    }

    @Test func v2AcceptanceBlocksLegacyFallbackAfterPairCacheRemoval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-model-downgrade-floor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let v2URL = URL(string: "https://catalog.test/catalog-v2.json")!
        let v2SignatureURL = URL(string: "https://catalog.test/catalog-v2.sig")!
        let v1URL = URL(string: "https://legacy.test/catalog-v1.json")!
        let v1SignatureURL = URL(string: "https://legacy.test/catalog-v1.sig")!
        let artifactBaseURL = URL(string: "https://catalog.test/models/")!
        let key = Curve25519.Signing.PrivateKey()
        let current = try encodedV2(sequence: 10, artifactBaseURL: artifactBaseURL)
        let legacy = MLRemoteModelCatalogDocument(models: [
            .init(
                id: MLModelCatalogEntry.tinyCLIPVit40M.id, revision: "legacy",
                artifacts: [
                    .init(
                        path: "TinyCLIP.mlmodelc/weights.bin",
                        url: artifactBaseURL.appendingPathComponent("tiny/legacy/TinyCLIP.mlmodelc/weights.bin"),
                        sha256: String(repeating: "a", count: 64),
                        bytes: 12
                    )
                ])
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacyData = try encoder.encode(legacy)
        StubProtocol.configure(responses: [
            v2URL: current.data,
            v2SignatureURL: try key.signature(for: current.data),
        ])
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            version: .v2,
            session: stubSession(),
            catalogURL: v2URL,
            signatureURL: v2SignatureURL,
            legacyCatalogURL: v1URL,
            legacySignatureURL: v1SignatureURL,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )

        _ = try await provider.catalog()
        try FileManager.default.removeItem(at: root.appendingPathComponent("catalog-v2.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("catalog-v2.sig"))
        StubProtocol.configure(responses: [
            v1URL: legacyData,
            v1SignatureURL: try key.signature(for: legacyData),
        ])

        await #expect(throws: (any Error).self) {
            _ = try await provider.catalog()
        }
        #expect(!StubProtocol.recordedRequests.contains { $0.url == v1URL })
    }

    @Test func v2ProviderBootstrapsFromVerifiedLegacyCacheBeforePairAcceptance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-model-default-v1-cache-\(UUID().uuidString)", isDirectory: true)
        let legacyRoot = root.appendingPathComponent("SmartSearch", isDirectory: true)
        let catalogRoot = root.appendingPathComponent("MLModelCatalog", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pairURL = URL(string: "https://catalog.test/active-pair.json")!
        let v2SignatureURL = URL(string: "https://catalog.test/catalog-v2.sig")!
        let v1URL = URL(string: "https://catalog.test/catalog-v1.json")!
        let v1SignatureURL = URL(string: "https://catalog.test/catalog-v1.sig")!
        let artifactBaseURL = URL(string: "https://catalog.test/models/")!
        let legacy = MLRemoteModelCatalogDocument(models: [
            .init(
                id: MLModelCatalogEntry.tinyCLIPVit40M.id,
                revision: "legacy",
                artifacts: [
                    .init(
                        path: "TinyCLIP.mlmodelc/weights.bin",
                        url: artifactBaseURL.appendingPathComponent("tiny/legacy/weights.bin"),
                        sha256: String(repeating: "a", count: 64),
                        bytes: 12
                    )
                ]
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacyData = try encoder.encode(legacy)
        let key = Curve25519.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try legacyData.write(to: legacyRoot.appendingPathComponent("catalog-v1.json"))
        try key.signature(for: legacyData).write(to: legacyRoot.appendingPathComponent("catalog-v1.sig"))
        StubProtocol.configure(responses: [:])

        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: catalogRoot,
            version: .v2,
            session: stubSession(),
            catalogURL: pairURL,
            signatureURL: v2SignatureURL,
            legacyCatalogURL: v1URL,
            legacySignatureURL: v1SignatureURL,
            legacyCacheDirectory: legacyRoot,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )

        let resolved = try await provider.catalog()
        #expect(resolved.entry(for: MLModelCatalogEntry.tinyCLIPVit40M.id)?.downloadPlan?.totalByteCount == 12)
        #expect(
            !FileManager.default.fileExists(
                atPath: catalogRoot.appendingPathComponent("catalog-v2.accepted.json").path
            ))
        #expect(StubProtocol.recordedRequests.contains { $0.url == pairURL })
        #expect(StubProtocol.recordedRequests.contains { $0.url == v1URL })
    }

    @Test func atomicPointerResolvesOneSignedContentAddressedPair() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-model-pointer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pointerURL = URL(string: "https://catalog.test/active-pair.json")!
        let artifactBaseURL = URL(string: "https://catalog.test/models/")!
        let key = Curve25519.Signing.PrivateKey()
        let catalog = try encodedV2(sequence: 12, artifactBaseURL: artifactBaseURL)
        let v1Document = MLRemoteModelCatalogDocument(models: [
            .init(
                id: MLModelCatalogEntry.tinyCLIPVit40M.id,
                revision: "revision-12",
                artifacts: [
                    .init(
                        path: "TinyCLIP.mlmodelc/weights.bin",
                        url: artifactBaseURL.appendingPathComponent("tiny/revision-12/weights.bin"),
                        sha256: String(repeating: "a", count: 64),
                        bytes: 123
                    )
                ]
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let v1Data = try encoder.encode(v1Document)
        let pairData = Data("release-pair-12".utf8)
        let pairID = sha256(pairData)
        let basePath = "catalog-history/\(pairID)"
        let objectValues: [(String, Data)] = [
            ("catalog-v1.json", v1Data),
            ("catalog-v1.sig", try key.signature(for: v1Data)),
            ("catalog-v2.json", catalog.data),
            ("catalog-v2.sig", try key.signature(for: catalog.data)),
            ("release-pair.json", pairData),
        ]
        let objects = objectValues.map { name, data in
            TestActivePointerObject(
                name: name,
                path: "\(basePath)/\(name)",
                sha256: sha256(data),
                bytes: data.count
            )
        }
        let payload = TestActivePointerPayload(
            schemaVersion: 1,
            pairID: pairID,
            catalogSequence: 12,
            objects: objects
        )
        let payloadEncoder = JSONEncoder()
        payloadEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadData = try payloadEncoder.encode(payload)
        let payloadJSON = try JSONSerialization.jsonObject(with: payloadData)
        let pointer: [String: Any] = [
            "payload": payloadJSON,
            "signature": try key.signature(for: payloadData).base64EncodedString(),
        ]
        let pointerData = try JSONSerialization.data(withJSONObject: pointer, options: [.sortedKeys])
        var responses: [URL: Data] = [pointerURL: pointerData]
        for (name, data) in objectValues {
            responses[pointerURL.deletingLastPathComponent().appendingPathComponent("\(basePath)/\(name)")] = data
        }
        StubProtocol.configure(responses: responses)
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            version: .v2,
            session: stubSession(),
            catalogURL: pointerURL,
            signatureURL: URL(string: "https://catalog.test/catalog-v2.sig")!,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )

        let resolved = try await provider.catalog()
        #expect(resolved.entry(for: MLModelCatalogEntry.tinyCLIPVit40M.id)?.downloadPlan?.totalByteCount == 123)
    }

    @Test func atomicPointerFailureKeepsThePreviousPairCacheIntact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-model-pointer-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pointerURL = URL(string: "https://catalog.test/active-pair.json")!
        let artifactBaseURL = URL(string: "https://catalog.test/models/")!
        let key = Curve25519.Signing.PrivateKey()
        let catalog = try encodedV2(sequence: 12, artifactBaseURL: artifactBaseURL)
        let v1Document = MLRemoteModelCatalogDocument(models: [
            .init(
                id: MLModelCatalogEntry.tinyCLIPVit40M.id,
                revision: "revision-12",
                artifacts: [
                    .init(
                        path: "TinyCLIP.mlmodelc/weights.bin",
                        url: artifactBaseURL.appendingPathComponent("tiny/revision-12/weights.bin"),
                        sha256: String(repeating: "a", count: 64),
                        bytes: 123
                    )
                ]
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let v1Data = try encoder.encode(v1Document)
        let pairData = Data("release-pair-12".utf8)
        let pairID = sha256(pairData)
        let objectValues: [(String, Data)] = [
            ("catalog-v1.json", v1Data),
            ("catalog-v1.sig", try key.signature(for: v1Data)),
            ("catalog-v2.json", catalog.data),
            ("catalog-v2.sig", try key.signature(for: catalog.data)),
            ("release-pair.json", pairData),
        ]
        let pointerObjects = objectValues.map { name, data in
            TestActivePointerObject(
                name: name,
                path: "catalog-history/\(pairID)/\(name)",
                sha256: sha256(data),
                bytes: data.count
            )
        }
        let payload = TestActivePointerPayload(
            schemaVersion: 1,
            pairID: pairID,
            catalogSequence: 12,
            objects: pointerObjects
        )
        let payloadEncoder = JSONEncoder()
        payloadEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadData = try payloadEncoder.encode(payload)
        let pointer: [String: Any] = [
            "payload": try JSONSerialization.jsonObject(with: payloadData),
            "signature": try key.signature(for: payloadData).base64EncodedString(),
        ]
        let pointerData = try JSONSerialization.data(withJSONObject: pointer, options: [.sortedKeys])
        var responses: [URL: Data] = [pointerURL: pointerData]
        for (name, data) in objectValues {
            responses[
                pointerURL.deletingLastPathComponent().appendingPathComponent("catalog-history/\(pairID)/\(name)")] =
                data
        }
        StubProtocol.configure(responses: responses)
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            version: .v2,
            session: stubSession(),
            catalogURL: pointerURL,
            signatureURL: URL(string: "https://catalog.test/catalog-v2.sig")!,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )

        _ = try await provider.catalog()
        let pointerCacheURL = root.appendingPathComponent("active-pair/active-pair.json")
        let pairCacheURL = root.appendingPathComponent("active-pair/\(pairID)/catalog-v2.json")
        #expect(FileManager.default.fileExists(atPath: pointerCacheURL.path))
        #expect(try Data(contentsOf: pointerCacheURL) == pointerData)
        #expect(try Data(contentsOf: pairCacheURL) == catalog.data)

        let failureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-model-pointer-hash-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: failureRoot) }
        var tamperedResponses = responses
        tamperedResponses[
            pointerURL.deletingLastPathComponent().appendingPathComponent("catalog-history/\(pairID)/catalog-v1.json")] =
            Data("tampered".utf8)
        StubProtocol.configure(responses: tamperedResponses)
        let failingProvider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: failureRoot,
            version: .v2,
            session: stubSession(),
            catalogURL: pointerURL,
            signatureURL: URL(string: "https://catalog.test/catalog-v2.sig")!,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )
        await #expect(throws: MLRemoteCatalogTransportError.activeCatalogObjectMismatch("catalog-v1.json")) {
            _ = try await failingProvider.catalog()
        }

        let interruptedPairID = String(repeating: "c", count: 64)
        let interruptedPayload = TestActivePointerPayload(
            schemaVersion: 1,
            pairID: interruptedPairID,
            catalogSequence: 13,
            objects: pointerObjects.map { object in
                TestActivePointerObject(
                    name: object.name,
                    path: "catalog-history/\(interruptedPairID)/\(object.name)",
                    sha256: object.sha256,
                    bytes: object.bytes
                )
            }
        )
        let interruptedPayloadData = try payloadEncoder.encode(interruptedPayload)
        let interruptedPointer: [String: Any] = [
            "payload": try JSONSerialization.jsonObject(with: interruptedPayloadData),
            "signature": try key.signature(for: interruptedPayloadData).base64EncodedString(),
        ]
        StubProtocol.configure(responses: [
            pointerURL: try JSONSerialization.data(withJSONObject: interruptedPointer, options: [.sortedKeys])
        ])

        let cached = try await provider.catalog()
        #expect(cached.entry(for: MLModelCatalogEntry.tinyCLIPVit40M.id)?.downloadPlan?.totalByteCount == 123)
        #expect(try Data(contentsOf: pointerCacheURL) == pointerData)
        #expect(try Data(contentsOf: pairCacheURL) == catalog.data)
    }

    @Test func atomicPointerRejectsPathEscapeBeforeFetchingPair() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-model-pointer-escape-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pointerURL = URL(string: "https://catalog.test/active-pair.json")!
        let key = Curve25519.Signing.PrivateKey()
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "pairID": String(repeating: "a", count: 64),
            "catalogSequence": 1,
            "objects": (1...5).map { index in
                [
                    "name": index == 1 ? "catalog-v1.json" : "catalog-v\(index).sig",
                    "path": index == 1
                        ? "catalog-history/\(String(repeating: "a", count: 64))/../catalog-v1.json" : "safe",
                    "sha256": String(repeating: "b", count: 64),
                    "bytes": 1,
                ] as [String: Any]
            },
        ]
        let encoder = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let pointer: [String: Any] = [
            "payload": payload,
            "signature": try key.signature(for: encoder).base64EncodedString(),
        ]
        StubProtocol.configure(responses: [
            pointerURL: try JSONSerialization.data(withJSONObject: pointer, options: [.sortedKeys])
        ])
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            version: .v2,
            session: stubSession(),
            catalogURL: pointerURL,
            signatureURL: URL(string: "https://catalog.test/catalog-v2.sig")!,
            artifactBaseURL: URL(string: "https://catalog.test/models/")!,
            publicKey: key.publicKey.rawRepresentation
        )

        await #expect(throws: MLRemoteCatalogTransportError.invalidActiveCatalogPointer) {
            _ = try await provider.catalog()
        }
        #expect(StubProtocol.recordedRequests.count == 1)
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func encodedV2(
        sequence: UInt64,
        modelReleaseSequence: UInt64? = nil,
        revision: String? = nil,
        artifactBaseURL: URL
    ) throws -> (data: Data, document: MLRemoteModelCatalogDocumentV2) {
        let id = MLModelCatalogEntry.tinyCLIPVit40M.id
        let document = MLRemoteModelCatalogDocumentV2(
            catalogSequence: sequence,
            models: [
                .init(
                    id: id,
                    compatibilityKey: "clip-dual-encoder-v1",
                    releaseSequence: modelReleaseSequence ?? sequence,
                    revision: revision ?? "revision-\(sequence)",
                    descriptor: .init(identifier: id.rawValue, version: 1, embeddingDimension: 512),
                    sourceRevision: String(repeating: "b", count: 40),
                    licenseIdentifier: "MIT",
                    role: "dualEncoder",
                    capabilities: ["imageEmbedding", "textEmbedding"],
                    artifacts: [
                        .init(
                            path: "TinyCLIP.mlmodelc/weights.bin",
                            url: artifactBaseURL.appendingPathComponent("tiny/revision/weights.bin"),
                            sha256: String(repeating: "a", count: 64),
                            bytes: 123
                        )
                    ]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try encoder.encode(document), document)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
