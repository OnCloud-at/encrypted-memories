import CoreGraphics
import Foundation
import ImageIO
import PhotosCore
import Testing

@testable import MLSearchAppleAdapter
@testable import MLSearchCore

/// Optional quality checks for a local SigLIP2 artifact.
/// Set `ENCRYPTED_MEMORIES_SIGLIP2_ARTIFACT` to an artifact directory containing the model and tokenizer files.
/// Set `ENCRYPTED_MEMORIES_ML_REFERENCE_CORPUS` to enable photo-ranking checks.
@Suite struct SigLIP2QualityReferenceTests {
    private static let descriptor = MLModelCatalogEntry.sigLIP2Base256.descriptor

    private struct FixtureDocument: Decodable {
        struct Fixture: Decodable {
            let text: String
            let inputIDs: [Int32]

            private enum CodingKeys: String, CodingKey {
                case text
                case inputIDs = "input_ids"
            }
        }

        let contextLength: Int
        let fixtures: [Fixture]

        private enum CodingKeys: String, CodingKey {
            case contextLength = "context_length"
            case fixtures
        }
    }

    private struct FileImageSource: CoreMLImageSource {
        let urlsByUID: [PhotoUID: URL]

        func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome {
            guard let url = urlsByUID[uid],
                let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                return .permanentFailure(reason: "unreadable reference image")
            }
            return .image(CoreMLSourceImage(cgImage: image))
        }
    }

    private struct EmptyImageSource: CoreMLImageSource {
        func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome { .transientFailure }
    }

    private static func artifactDirectory() -> URL? {
        ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_SIGLIP2_ARTIFACT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func makeEncoder(artifact: URL, imageSource: any CoreMLImageSource) async throws -> CoreMLDualEncoder
    {
        let entry = MLModelCatalogEntry.sigLIP2Base256
        let modelCandidates = try FileManager.default.contentsOfDirectory(
            at: artifact,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { ["mlmodelc", "mlpackage"].contains($0.pathExtension.lowercased()) }
        let modelArtifact = try #require(modelCandidates.count == 1 ? modelCandidates.first : nil)
        let tokenizer = try SentencePieceBPETokenizer(
            fileURL: artifact.appendingPathComponent("tokenizer.json")
        )
        #expect(tokenizer.contextLength == entry.runtimeContract.textContextLength)
        var schema = CoreMLDualEncoderSchema(contract: entry.runtimeContract)
        schema.imageCropMode = try AppleSmartSearchRuntimeProvider.cropMode(for: entry.preprocessingID)
        let buildRoot =
            ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_BUILD_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/xcode/EncryptedMemories", isDirectory: true)
        let runtimeCache =
            buildRoot
            .appendingPathComponent("MLQualityRuntime.noindex", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runtimeCache) }
        let modelURL = try await AppleSmartSearchRuntimeProvider.loadableModelURL(
            artifactURL: modelArtifact,
            runtimeCacheDirectory: runtimeCache
        )
        return try await CoreMLDualEncoder(
            modelURL: modelURL,
            descriptor: descriptor,
            imageSource: imageSource,
            tokenizer: tokenizer,
            schema: schema
        )
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_SIGLIP2_ARTIFACT"] != nil))
    func optionalTokenizerMatchesUpstreamFixturesExactly() throws {
        let artifact = try #require(Self.artifactDirectory())
        let tokenizer = try SentencePieceBPETokenizer(
            fileURL: artifact.appendingPathComponent("tokenizer.json")
        )
        let document = try JSONDecoder().decode(
            FixtureDocument.self,
            from: Data(contentsOf: artifact.appendingPathComponent("tokenizer-fixtures.json"))
        )
        #expect(tokenizer.contextLength == document.contextLength)
        for fixture in document.fixtures {
            let tokenized = try tokenizer.tokenize(fixture.text)
            #expect(Array(tokenized.inputIDs) == fixture.inputIDs, "\"\(fixture.text)\"")
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_SIGLIP2_ARTIFACT"] != nil),
        .timeLimit(.minutes(10))
    )
    func optionalRuntimeContractAndDualEmbeddingSmoke() async throws {
        let artifact = try #require(Self.artifactDirectory())
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256 * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let image = try #require(context.makeImage())
        let encoder = try await Self.makeEncoder(
            artifact: artifact,
            imageSource: FileImageSource(urlsByUID: [:])
        )
        _ = encoder  // contract validated in init (functions, ids-only text input, 256px, 768-d)

        let direct = try await Self.makeEncoder(
            artifact: artifact,
            imageSource: CachedThumbnailMLImageSourceStandIn(image: image)
        )
        let imageOutcome = await direct.embed(
            uid: PhotoUID(volumeID: "v", nodeID: "smoke"), descriptor: Self.descriptor)
        guard case .embedded(let imageEmbedding) = imageOutcome else {
            Issue.record("expected image embedding")
            return
        }
        let textEmbedding = try await direct.encode(text: "ein Foto von einem Hund", descriptor: Self.descriptor)
        #expect(imageEmbedding.count == 768)
        #expect(textEmbedding.count == 768)
        #expect(imageEmbedding.allSatisfy { $0.isFinite })
        #expect(textEmbedding.allSatisfy { $0.isFinite })
    }

    private struct CachedThumbnailMLImageSourceStandIn: CoreMLImageSource {
        let image: CGImage
        func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome {
            .image(CoreMLSourceImage(cgImage: image))
        }
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_SIGLIP2_ARTIFACT"] != nil
                && ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_ML_REFERENCE_CORPUS"] != nil),
        .timeLimit(.minutes(10))
    )
    func optionalRealPhotoCorpusRankingGermanAndEnglish() async throws {
        let artifact = try #require(Self.artifactDirectory())
        let corpusPath = try #require(ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_ML_REFERENCE_CORPUS"])
        let corpusURL = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: corpusURL, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        try #require(!files.isEmpty, "reference corpus directory is empty")

        let concepts = TinyCLIPQualityReferenceTests.concepts
        var urlsByUID: [PhotoUID: URL] = [:]
        var conceptByUID: [PhotoUID: String] = [:]
        for file in files {
            guard let concept = concepts.first(where: { file.lastPathComponent.hasPrefix($0.concept) })?.concept else {
                continue
            }
            let uid = PhotoUID(volumeID: "ref", nodeID: file.lastPathComponent)
            urlsByUID[uid] = file
            conceptByUID[uid] = concept
        }
        try #require(
            Set(conceptByUID.values).count == concepts.count,
            "corpus must contain at least one photo per concept: \(concepts.map(\.concept))")

        let encoder = try await Self.makeEncoder(
            artifact: artifact,
            imageSource: FileImageSource(urlsByUID: urlsByUID)
        )

        var block = MLVectorBlock(descriptor: Self.descriptor)
        for uid in urlsByUID.keys.sorted(by: { $0.nodeID < $1.nodeID }) {
            guard case .embedded(let vector) = await encoder.embed(uid: uid, descriptor: Self.descriptor),
                let normalized = MLVectorNormalization.normalized(vector)
            else {
                Issue.record("failed to embed reference image \(uid.nodeID)")
                continue
            }
            block.append(uid: uid, vector: normalized)
        }

        let scorer = AccelerateVectorScorer()
        var englishHits = 0
        var germanHits = 0
        var report: [String] = []
        for entry in concepts {
            for (label, query, isEnglish) in [("en", entry.english, true), ("de", entry.german, false)] {
                let raw = try await encoder.encode(text: query, descriptor: Self.descriptor)
                guard let normalized = MLVectorNormalization.normalized(raw) else { continue }
                let results = scorer.rank(block: block, query: normalized, limit: 3, queryText: query)
                let topConcept = results.results.first.flatMap { conceptByUID[$0.uid] } ?? "-"
                let hit = topConcept == entry.concept
                if hit { if isEnglish { englishHits += 1 } else { germanHits += 1 } }
                report.append("[\(label)] \(query) → top1=\(topConcept) \(hit ? "HIT" : "MISS")")
            }
        }
        print(
            "[siglip2-quality] corpus ranking en=\(englishHits)/\(concepts.count) de=\(germanHits)/\(concepts.count)\n"
                + report.joined(separator: "\n"))
        // The multilingual check allows bounded corpus variance while requiring both languages to pass.
        #expect(englishHits >= concepts.count * 3 / 4)
        #expect(germanHits >= concepts.count * 3 / 4, "German must remain near English parity")
    }

    /// Optional calibration corpus for the exact production query shape. Files whose names start
    /// with `positive-` must contain horses; `negative-` files must not. This keeps private test
    /// photos outside Git while evaluating score separation for the shipped artifact.
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_SIGLIP2_ARTIFACT"] != nil
                && ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_ML_HORSE_CORPUS"] != nil),
        .timeLimit(.minutes(10))
    )
    func optionalProductionHorseQueryScoreDistribution() async throws {
        let artifact = try #require(Self.artifactDirectory())
        let corpusPath = try #require(ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_ML_HORSE_CORPUS"])
        let corpusURL = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: corpusURL, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        let positives = files.filter { $0.lastPathComponent.hasPrefix("positive-") }
        let negatives = files.filter { $0.lastPathComponent.hasPrefix("negative-") }
        try #require(!positives.isEmpty && !negatives.isEmpty, "corpus needs positive-* and negative-* images")

        var urlsByUID: [PhotoUID: URL] = [:]
        var positiveUIDs = Set<PhotoUID>()
        for file in positives + negatives {
            let uid = PhotoUID(volumeID: "horse-calibration", nodeID: file.lastPathComponent)
            urlsByUID[uid] = file
            if file.lastPathComponent.hasPrefix("positive-") { positiveUIDs.insert(uid) }
        }

        let encoder = try await Self.makeEncoder(
            artifact: artifact,
            imageSource: FileImageSource(urlsByUID: urlsByUID)
        )
        var block = MLVectorBlock(descriptor: Self.descriptor)
        for uid in urlsByUID.keys.sorted(by: { $0.nodeID < $1.nodeID }) {
            guard case .embedded(let vector) = await encoder.embed(uid: uid, descriptor: Self.descriptor),
                let normalized = MLVectorNormalization.normalized(vector)
            else {
                Issue.record("failed to embed calibration image \(uid.nodeID)")
                continue
            }
            block.append(uid: uid, vector: normalized)
        }
        #expect(block.count == urlsByUID.count)

        let scorer = AccelerateVectorScorer()
        for (query, expectsHorses) in [
            ("horse", true),
            ("Pferd", true),
            ("elephant", false),
        ] {
            let raw = try await encoder.encode(text: query, descriptor: Self.descriptor)
            let normalized = try #require(MLVectorNormalization.normalized(raw))
            let results = scorer.rank(block: block, query: normalized, limit: block.count, queryText: query).results
            let relevantResults = MLModelCatalogEntry.sigLIP2Base256.relevancePolicy.relevantResults(from: results)
            let positiveScores = results.filter { positiveUIDs.contains($0.uid) }.map(\.score)
            let negativeScores = results.filter { !positiveUIDs.contains($0.uid) }.map(\.score)
            let topPositiveRank = try #require(results.firstIndex { positiveUIDs.contains($0.uid) }).advanced(by: 1)
            let topTwelvePositiveCount = results.prefix(12).count { positiveUIDs.contains($0.uid) }
            print(
                "[siglip2-horse] \(query) positives=\(positiveScores.count) negatives=\(negativeScores.count) "
                    + "positiveRange=\(positiveScores.min() ?? 0)...\(positiveScores.max() ?? 0) "
                    + "negativeRange=\(negativeScores.min() ?? 0)...\(negativeScores.max() ?? 0) "
                    + "topPositiveRank=\(topPositiveRank) top12Positives=\(topTwelvePositiveCount) "
                    + "relevant=\(relevantResults.count)\n"
                    + results.prefix(20).enumerated().map {
                        "\($0.offset + 1). \($0.element.uid.nodeID) \($0.element.score)"
                    }.joined(separator: "\n")
            )
            if expectsHorses {
                #expect(topPositiveRank == 1)
                #expect(topTwelvePositiveCount >= 8)
                #expect(relevantResults.count == positiveUIDs.count)
                #expect(relevantResults.allSatisfy { positiveUIDs.contains($0.uid) })
            } else if query == "elephant" {
                #expect(relevantResults.isEmpty)
            }
        }
    }
}
