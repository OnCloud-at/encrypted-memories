import PhotosCore
import XCTest

@testable import MLSearchCore

final class MLPipelineDefinitionTests: XCTestCase {
    func testSemanticStageUsesCurrentProviderCodableShape() throws {
        let stage = MLPipelineStage(
            id: .init(rawValue: "semanticImage"),
            provider: .model(id: .init("semantic"), role: .dualEncoder),
            operation: .imageEmbedding(namespace: "semantic-v1")
        )
        let data = try JSONEncoder().encode(stage)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(object["modelID"])
        XCTAssertNotNil(object["provider"])
        XCTAssertNil(object["output"])
        XCTAssertEqual(try JSONDecoder().decode(MLPipelineStage.self, from: data), stage)
    }

    func testOCRPipelineUsesNativeProviderWithoutModelOrTokenizer() throws {
        let stage = MLPipelineStage(
            id: .init(rawValue: "ocr"),
            provider: .native(
                kind: .textRecognition,
                implementationIdentifier: "apple.vision.recognize-text",
                requestRevision: "revision3"
            ),
            operation: .nativeAnalysis(.textRecognition),
            output: .recognizedText
        )
        let pipeline = try MLPipelineDefinition(
            id: .nativeSearch,
            feature: .smartSearch,
            stages: [stage]
        )
        let decoded = try JSONDecoder().decode(
            MLPipelineDefinition.self,
            from: JSONEncoder().encode(pipeline)
        )

        XCTAssertEqual(decoded, pipeline)
        XCTAssertNil(decoded.stages[0].modelID)
    }

    func testPeopleDetectorToEmbedderGraphIsTyped() throws {
        let detector = MLStageID(rawValue: "faceDetector")
        let space = try MLDescriptorSpace(identifier: "people-face", revision: 1, dimension: 128)
        let pipeline = try MLPipelineDefinition(
            id: .people,
            feature: .peopleRecognition,
            stages: [
                .init(
                    id: detector,
                    provider: .native(
                        kind: .faceDetection,
                        implementationIdentifier: "apple.vision.face-detection",
                        requestRevision: "revision3"
                    ),
                    operation: .nativeAnalysis(.faceDetection),
                    output: .regions(labels: ["human"], species: [.human], landmarkSchema: nil)
                ),
                .init(
                    id: .init(rawValue: "faceEmbedder"),
                    provider: .model(id: .init("sface"), role: .regionEmbedder),
                    operation: .regionEmbedding(namespace: "people-face"),
                    input: .regions(producedBy: detector, matchingLabels: ["human"]),
                    dependsOn: [detector],
                    output: .regionEmbedding(space: space, species: .human)
                ),
            ]
        )

        XCTAssertEqual(pipeline.stages.count, 2)
    }

    func testConditionalPipelineIsAValidatedDAG() throws {
        let detector = MLStageID(rawValue: "petDetector")
        let catEmbedder = MLStageID(rawValue: "catEmbedder")
        let dogEmbedder = MLStageID(rawValue: "dogEmbedder")
        let pipeline = try MLPipelineDefinition(
            id: .pets,
            feature: .petRecognition,
            stages: [
                .init(
                    id: detector, provider: .model(id: .init("detector"), role: .regionDetector),
                    operation: .regionDetection(labels: ["cat", "dog"])),
                .init(
                    id: catEmbedder,
                    provider: .model(id: .init("cat-embedder"), role: .regionEmbedder),
                    operation: .regionEmbedding(namespace: "cat-faces"),
                    input: .regions(producedBy: detector, matchingLabels: ["cat"]),
                    dependsOn: [detector]
                ),
                .init(
                    id: dogEmbedder,
                    provider: .model(id: .init("dog-embedder"), role: .regionEmbedder),
                    operation: .regionEmbedding(namespace: "dog-faces"),
                    input: .regions(producedBy: detector, matchingLabels: ["dog"]),
                    dependsOn: [detector]
                ),
            ]
        )
        XCTAssertEqual(pipeline.stages.count, 3)
    }

    func testPipelineRejectsRegionLabelTheDetectorCannotProduce() {
        let detector = MLStageID(rawValue: "petDetector")
        XCTAssertThrowsError(
            try MLPipelineDefinition(
                id: .pets,
                feature: .petRecognition,
                stages: [
                    .init(
                        id: detector, provider: .model(id: .init("detector"), role: .regionDetector),
                        operation: .regionDetection(labels: ["cat"])),
                    .init(
                        id: .init(rawValue: "dogEmbedder"),
                        provider: .model(id: .init("dog-embedder"), role: .regionEmbedder),
                        operation: .regionEmbedding(namespace: "dog-faces"),
                        input: .regions(producedBy: detector, matchingLabels: ["dog"]),
                        dependsOn: [detector]
                    ),
                ]
            )
        ) { XCTAssertEqual($0 as? MLPipelineDefinitionError, .invalidInput) }
    }

    func testPetPipelineRejectsSpeciesMismatch() throws {
        let detector = MLStageID(rawValue: "petDetector")
        let space = try MLDescriptorSpace(identifier: "dog-face", revision: 1, dimension: 128)
        XCTAssertThrowsError(
            try MLPipelineDefinition(
                id: .pets,
                feature: .petRecognition,
                stages: [
                    .init(
                        id: detector,
                        provider: .native(
                            kind: .animalRecognition,
                            implementationIdentifier: "apple.vision.animals",
                            requestRevision: "revision2"
                        ),
                        operation: .nativeAnalysis(.animalRecognition),
                        output: .regions(labels: ["cat"], species: [.cat], landmarkSchema: nil)
                    ),
                    .init(
                        id: .init(rawValue: "dogEmbedder"),
                        provider: .model(id: .init("dog"), role: .regionEmbedder),
                        operation: .regionEmbedding(namespace: "dog-face"),
                        input: .regions(producedBy: detector, matchingLabels: ["dog"]),
                        dependsOn: [detector],
                        output: .regionEmbedding(space: space, species: .dog)
                    ),
                ]
            )
        ) { XCTAssertEqual($0 as? MLPipelineDefinitionError, .invalidInput) }
    }

    func testNativeOperationRejectsModelProviderAndWrongOutput() {
        XCTAssertThrowsError(
            try MLPipelineDefinition(
                id: .nativeSearch,
                feature: .smartSearch,
                stages: [
                    .init(
                        id: .init(rawValue: "ocr"),
                        provider: .model(id: .init("fake-native-model"), role: .textRecognizer),
                        operation: .nativeAnalysis(.textRecognition),
                        output: .recognizedText
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? MLPipelineDefinitionError,
                .providerRoleMismatch(.init(rawValue: "ocr"))
            )
        }

        XCTAssertThrowsError(
            try MLPipelineDefinition(
                id: .nativeSearch,
                feature: .smartSearch,
                stages: [
                    .init(
                        id: .init(rawValue: "ocr"),
                        provider: .native(
                            kind: .textRecognition,
                            implementationIdentifier: "apple.vision.recognize-text",
                            requestRevision: "revision3"
                        ),
                        operation: .nativeAnalysis(.textRecognition),
                        output: .barcodePayload
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? MLPipelineDefinitionError,
                .outputMismatch(.init(rawValue: "ocr"))
            )
        }
    }

    func testCycleIsRejected() {
        let a = MLStageID(rawValue: "a")
        let b = MLStageID(rawValue: "b")
        XCTAssertThrowsError(
            try MLPipelineDefinition(
                id: .people,
                feature: .peopleRecognition,
                stages: [
                    .init(
                        id: a, provider: .model(id: .init("a"), role: .regionDetector),
                        operation: .regionDetection(labels: []), dependsOn: [b]),
                    .init(
                        id: b, provider: .model(id: .init("b"), role: .regionEmbedder),
                        operation: .regionEmbedding(namespace: "faces"), dependsOn: [a]),
                ]
            )
        ) { XCTAssertEqual($0 as? MLPipelineDefinitionError, .cycle) }
    }

    func testRegistryRejectsModelWithWrongCapability() throws {
        let model = MLModelCatalogEntry(
            id: .init("semantic"), displayName: "Semantic", family: "Test",
            descriptor: .init(identifier: "semantic", version: 1, embeddingDimension: 2),
            tokenizerID: "tokenizer", preprocessingID: "preprocess", license: .mit,
            releaseTrack: .developerOnly, estimatedInstalledBytes: 1, downloadPlan: nil
        )
        let stage = MLPipelineStage(
            id: .init(rawValue: "detector"), provider: .model(id: model.id, role: .regionDetector),
            operation: .regionDetection(labels: ["person"])
        )
        let registry = MLPipelineRegistry([try .init(id: .people, feature: .peopleRecognition, stages: [stage])])
        XCTAssertThrowsError(try registry.validate(models: .init(entries: [model])))
    }

    func testRegistryRejectsEmbeddingDimensionMismatch() throws {
        let model = MLModelCatalogEntry(
            id: .init("region"), displayName: "Region", family: "Test",
            capabilities: [.regionEmbedding],
            descriptor: .init(identifier: "region", version: 1, embeddingDimension: 128),
            tokenizerID: "none", preprocessingID: "face-112", license: .mit,
            releaseTrack: .developerOnly, estimatedInstalledBytes: 1, downloadPlan: nil
        )
        let space = try MLDescriptorSpace(identifier: "people", revision: 1, dimension: 256)
        let stage = MLPipelineStage(
            id: .init(rawValue: "embedder"),
            provider: .model(id: model.id, role: .regionEmbedder),
            operation: .regionEmbedding(namespace: "people"),
            output: .regionEmbedding(space: space, species: .human)
        )
        let registry = MLPipelineRegistry([
            try .init(id: .people, feature: .peopleRecognition, stages: [stage])
        ])

        XCTAssertThrowsError(try registry.validate(models: .init(entries: [model]))) { error in
            XCTAssertEqual(
                error as? MLPipelineRegistryError,
                .dimensionMismatch(model.id, stage.id, expected: 128, actual: 256)
            )
        }
    }

    func testRegistryValidatesNativeCapabilityAndRevision() throws {
        let stage = MLPipelineStage(
            id: .init(rawValue: "ocr"),
            provider: .native(
                kind: .textRecognition,
                implementationIdentifier: "apple.vision.recognize-text",
                requestRevision: "revision3"
            ),
            operation: .nativeAnalysis(.textRecognition),
            output: .recognizedText
        )
        let registry = MLPipelineRegistry([
            try .init(id: .nativeSearch, feature: .smartSearch, stages: [stage])
        ])
        let capabilities = MLNativeAnalysisCapabilitySnapshot(
            providerIdentifier: "apple.vision",
            sdkIdentifier: "iphoneos26.5",
            capabilities: [
                MLNativeAnalysisCapability(
                    kind: .textRecognition,
                    implementationIdentifier: "apple.vision.recognize-text",
                    availability: .available,
                    selectedRevision: "revision3",
                    supportedRevisions: ["revision3"]
                )
            ]
        )

        XCTAssertNoThrow(try registry.validate(models: .init(entries: []), nativeCapabilities: capabilities))
    }

    func testUnsupportedManifestVersionRequiresNarrowReset() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 9,
            "definitions": [],
        ])
        XCTAssertThrowsError(
            try MLPipelineManifest.decodeDerivedState(
                from: data,
                scope: .pipeline(.nativeSearch)
            )
        ) { error in
            XCTAssertEqual(
                error as? MLDerivedStateCompatibilityError,
                .resetRequired(scope: .pipeline(.nativeSearch), storedSchemaVersion: 9, supportedSchemaVersion: 1)
            )
        }
    }
}
