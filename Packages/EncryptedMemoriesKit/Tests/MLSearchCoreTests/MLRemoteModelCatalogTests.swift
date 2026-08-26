import Foundation
import Testing

@testable import MLSearchCore

@Suite struct MLRemoteModelCatalogTests {
    private let baseURL = URL(string: "https://models.oncloud.at/models/")!

    @Test func signedPayloadDataCanOnlyAttachDistributionToTrustedContracts() throws {
        let document = MLRemoteModelCatalogDocument(models: [
            .init(
                id: .tinyCLIPVit40M, revision: "r1-content",
                artifacts: [
                    artifact("TinyCLIP.mlmodelc/weights/weight.bin", bytes: 166_234_752)
                ]),
            .init(
                id: .sigLIP2Base256, revision: "r1-multilingual",
                artifacts: [
                    artifact("SigLIP2.mlmodelc/weights/weight.bin", bytes: 749_313_088),
                    artifact("tokenizer.json", bytes: 10_781_028),
                ]),
        ])

        let catalog = try MLRemoteModelCatalogResolver(
            trustedCatalog: .builtIn,
            allowedBaseURL: baseURL
        ).resolve(document)

        let tiny = try #require(catalog.entry(for: .tinyCLIPVit40M))
        #expect(tiny.descriptor == MLModelCatalogEntry.tinyCLIPVit40M.descriptor)
        #expect(tiny.downloadPlan?.totalByteCount == 166_234_752)
        #expect(tiny.isReleaseReady)
        let siglip = try #require(catalog.entry(for: .sigLIP2Base256))
        #expect(siglip.runtimeResourcePaths == ["tokenizer.json"])
        #expect(siglip.downloadPlan?.totalByteCount == 760_094_116)
        #expect(siglip.isReleaseReady)
        #expect(catalog.entries.count == 2)
    }

    @Test func optionalQualificationNeverControlsRuntimeAvailability() throws {
        let resolver = MLRemoteModelCatalogResolver(trustedCatalog: .builtIn, allowedBaseURL: baseURL)
        let legacy = try resolver.resolve(
            .init(models: [
                .init(
                    id: .tinyCLIPVit40M, revision: "legacy",
                    artifacts: [
                        artifact("TinyCLIP.mlmodelc/weights.bin")
                    ])
            ]))
        #expect(legacy.selectableEntries(allowsDeveloperModels: false).map(\.id) == [.tinyCLIPVit40M])

        let stale = try resolver.resolve(
            .init(models: [
                .init(
                    id: .tinyCLIPVit40M, revision: "current",
                    artifacts: [
                        artifact("TinyCLIP.mlmodelc/weights.bin")
                    ], qualification: qualification("old"))
            ]))
        #expect(stale.selectableEntries(allowsDeveloperModels: false).map(\.id) == [.tinyCLIPVit40M])
    }

    @Test func rejectsUnknownModelsAndUntrustedArtifactURLs() {
        let resolver = MLRemoteModelCatalogResolver(trustedCatalog: .builtIn, allowedBaseURL: baseURL)
        #expect(throws: MLRemoteModelCatalogError.unknownModel("future-model")) {
            _ = try resolver.resolve(
                .init(models: [
                    .init(id: MLModelID("future-model"), revision: "r1", artifacts: [artifact("Model.mlmodelc/a")])
                ]))
        }
        #expect(throws: MLRemoteModelCatalogError.invalidArtifactURL("https://example.test/model.bin")) {
            _ = try resolver.resolve(
                .init(models: [
                    .init(
                        id: .tinyCLIPVit40M, revision: "r1",
                        artifacts: [
                            .init(
                                path: "TinyCLIP.mlmodelc/a", url: URL(string: "https://example.test/model.bin")!,
                                sha256: String(repeating: "a", count: 64), bytes: 1)
                        ])
                ]))
        }
    }

    @Test func sigLIPRequiresItsPinnedTokenizerSidecar() {
        let resolver = MLRemoteModelCatalogResolver(trustedCatalog: .builtIn, allowedBaseURL: baseURL)
        #expect(throws: MLRemoteModelCatalogError.missingRuntimeResource("tokenizer.json")) {
            _ = try resolver.resolve(
                .init(models: [
                    .init(id: .sigLIP2Base256, revision: "r1", artifacts: [artifact("SigLIP2.mlmodelc/weights.bin")])
                ]))
        }
    }

    @Test func legacyCatalogRejectsUnsafeRevisionsAndRecipeSizeOverruns() {
        let resolver = MLRemoteModelCatalogResolver(trustedCatalog: .builtIn, allowedBaseURL: baseURL)
        for revision in [".", "..", "revision.1"] {
            #expect(throws: MLRemoteModelCatalogError.invalidRevision(revision)) {
                _ = try resolver.resolve(
                    .init(models: [
                        .init(
                            id: .tinyCLIPVit40M,
                            revision: revision,
                            artifacts: [artifact("TinyCLIP.mlmodelc/weights.bin")]
                        )
                    ]))
            }
        }
        #expect(throws: MLRemoteModelCatalogError.artifactSizeExceeded("TinyCLIP.mlmodelc/weights.bin")) {
            _ = try resolver.resolve(
                .init(models: [
                    .init(
                        id: .tinyCLIPVit40M,
                        revision: "oversized",
                        artifacts: [artifact("TinyCLIP.mlmodelc/weights.bin", bytes: 220_000_001)]
                    )
                ]))
        }
    }

    @Test func v2CatalogCanPublishACompatibleModelWithoutAnAppUpdate() throws {
        let id = MLModelID("tinyclip-compatible")
        let document = MLRemoteModelCatalogDocumentV2(
            catalogSequence: 7,
            models: [v2Model(id: id, descriptorVersion: 2)]
        )

        let catalog = try MLRemoteModelCatalogResolver(
            trustedCatalog: .builtIn,
            allowedBaseURL: baseURL
        ).resolve(document)

        let entry = try #require(catalog.entry(for: id))
        #expect(entry.compatibilityKey == "clip-dual-encoder-v1")
        #expect(entry.descriptor.identifier == id.rawValue)
        #expect(entry.descriptor.version == 2)
        #expect(entry.downloadPlan?.revision == "artifact-revision-2")
        #expect(entry.runtimeContract == MLModelCatalogEntry.tinyCLIPVit40M.runtimeContract)
        #expect(entry.isReleaseReady)
    }

    @Test func retiredV2ModelIsValidatedButNotSelectable() throws {
        let id = MLModelID.tinyCLIPVit40M
        let document = MLRemoteModelCatalogDocumentV2(
            catalogSequence: 8,
            models: [v2Model(id: id, availability: .retired)]
        )

        let catalog = try MLRemoteModelCatalogResolver(
            trustedCatalog: .builtIn,
            allowedBaseURL: baseURL
        ).resolve(document)

        #expect(catalog.entry(for: id) == nil)
    }

    @Test func retiredV2ModelStillValidatesItsArtifactPlan() {
        let id = MLModelID("tinyclip-retired")
        let invalidArtifact = MLRemoteModelCatalogDocument.Artifact(
            path: "TinyCLIP.mlmodelc/weights.bin",
            url: URL(string: "https://example.test/model.bin")!,
            sha256: String(repeating: "a", count: 64),
            bytes: 1
        )
        let document = MLRemoteModelCatalogDocumentV2(
            catalogSequence: 8,
            models: [v2Model(id: id, availability: .retired).replacingArtifacts([invalidArtifact])]
        )

        #expect(throws: MLRemoteModelCatalogError.invalidArtifactURL("https://example.test/model.bin")) {
            _ = try MLRemoteModelCatalogResolver(
                trustedCatalog: .builtIn,
                allowedBaseURL: baseURL
            ).resolve(document)
        }
    }

    @Test func v2CatalogRejectsMutableSourceRevisionAndUnsupportedDescriptor() {
        let resolver = MLRemoteModelCatalogResolver(
            trustedCatalog: .builtIn,
            allowedBaseURL: baseURL
        )
        let id = MLModelID("tinyclip-compatible")
        #expect(throws: MLRemoteModelCatalogError.invalidSourceRevision(id.rawValue)) {
            _ = try resolver.resolve(
                .init(
                    catalogSequence: 1,
                    models: [v2Model(id: id, sourceRevision: "main")]
                ))
        }
        #expect(throws: MLRemoteModelCatalogError.descriptorMismatch(id.rawValue)) {
            _ = try resolver.resolve(
                .init(
                    catalogSequence: 1,
                    models: [v2Model(id: id, descriptorVersion: 65_536)]
                ))
        }
        #expect(throws: MLRemoteModelCatalogError.invalidCatalogSequence) {
            _ = try resolver.resolve(
                .init(
                    catalogSequence: 0,
                    models: [v2Model(id: id)]
                ))
        }
        #expect(throws: MLRemoteModelCatalogError.invalidRevision("..")) {
            _ = try resolver.resolve(
                .init(
                    catalogSequence: 1,
                    models: [v2Model(id: id, revision: "..")]
                ))
        }
        #expect(throws: MLRemoteModelCatalogError.invalidModelReleaseSequence(id.rawValue)) {
            _ = try resolver.resolve(
                .init(
                    catalogSequence: 1,
                    models: [v2Model(id: id, releaseSequence: 0)]
                ))
        }
        #expect(throws: MLRemoteModelCatalogError.invalidModelLayout(id.rawValue)) {
            _ = try resolver.resolve(
                .init(
                    catalogSequence: 1,
                    models: [v2Model(id: id).replacingArtifacts([artifact("TinyCLIP.mlmodelc")])]
                ))
        }
    }

    @Test func v2CatalogRejectsUnicodeModelIDs() {
        let id = MLModelID("tést")

        #expect(throws: MLRemoteModelCatalogError.unsafeModelID(id.rawValue)) {
            _ = try MLRemoteModelCatalogResolver(
                trustedCatalog: .builtIn,
                allowedBaseURL: baseURL
            ).resolve(
                .init(
                    catalogSequence: 1,
                    models: [v2Model(id: id)]
                ))
        }
    }

    private func artifact(_ path: String, bytes: Int64 = 1) -> MLRemoteModelCatalogDocument.Artifact {
        .init(
            path: path,
            url: baseURL.appendingPathComponent("test/" + path),
            sha256: String(repeating: "a", count: 64),
            bytes: bytes
        )
    }

    private func qualification(_ revision: String) -> MLModelReleaseQualification {
        MLModelReleaseQualification(
            artifactRevision: revision,
            hardwareModel: "oldest-supported-iphone",
            osVersion: "26.0",
            peakResidentBytes: 100,
            imageP95Milliseconds: 10,
            textP95Milliseconds: 5,
            reachedSeriousThermalState: false,
            neuralEngineExecutionVerified: true,
            passed: true
        )
    }

    private func v2Model(
        id: MLModelID,
        availability: MLRemoteModelCatalogDocumentV2.Availability? = nil,
        releaseSequence: UInt64 = 1,
        revision: String = "artifact-revision-2",
        sourceRevision: String = String(repeating: "b", count: 40),
        descriptorVersion: Int = 1
    ) -> MLRemoteModelCatalogDocumentV2.Model {
        .init(
            id: id,
            availability: availability,
            compatibilityKey: "clip-dual-encoder-v1",
            releaseSequence: releaseSequence,
            revision: revision,
            descriptor: .init(
                identifier: id.rawValue,
                version: descriptorVersion,
                embeddingDimension: 512
            ),
            sourceRevision: sourceRevision,
            licenseIdentifier: "MIT",
            role: "dualEncoder",
            capabilities: ["imageEmbedding", "textEmbedding"],
            artifacts: [artifact("TinyCLIP.mlmodelc/weights.bin")]
        )
    }
}

private extension MLRemoteModelCatalogDocumentV2.Model {
    func replacingArtifacts(
        _ artifacts: [MLRemoteModelCatalogDocument.Artifact]
    ) -> MLRemoteModelCatalogDocumentV2.Model {
        .init(
            id: id,
            availability: availability,
            compatibilityKey: compatibilityKey,
            releaseSequence: releaseSequence,
            revision: revision,
            descriptor: descriptor,
            sourceRevision: sourceRevision,
            licenseIdentifier: licenseIdentifier,
            role: role,
            capabilities: capabilities,
            artifacts: artifacts,
            qualification: qualification
        )
    }
}

private extension MLModelID {
    static let tinyCLIPVit40M = MLModelCatalogEntry.tinyCLIPVit40M.id
    static let sigLIP2Base256 = MLModelCatalogEntry.sigLIP2Base256.id
}
