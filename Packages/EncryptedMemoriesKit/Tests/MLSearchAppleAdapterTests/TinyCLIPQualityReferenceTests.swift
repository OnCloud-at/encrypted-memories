import CoreGraphics
import Foundation
import ImageIO
import PhotosCore
import Testing

@testable import MLSearchAppleAdapter
@testable import MLSearchCore

/// Optional quality checks for a local TinyCLIP model.
/// Set `ENCRYPTED_MEMORIES_TINYCLIP_MODEL` to a converted Core ML artifact.
/// Set `ENCRYPTED_MEMORIES_ML_REFERENCE_CORPUS` to enable photo-ranking checks.
@Suite struct TinyCLIPQualityReferenceTests {
    static let concepts: [(concept: String, english: String, german: String)] = [
        ("trees", "a photo of trees", "Bäume"),
        ("beach", "a photo of a beach", "Strand"),
        ("dog", "a photo of a dog", "Hund"),
        ("car", "a photo of a car", "Auto"),
        ("people", "a photo of people", "Menschen"),
        ("food", "a photo of food", "Essen"),
        ("mountain", "a photo of a mountain", "Berg"),
        ("sunset", "a photo of a sunset", "Sonnenuntergang"),
    ]

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

    private func normalizedDot(_ a: ContiguousArray<Float32>, _ b: ContiguousArray<Float32>) -> Float {
        guard let na = MLVectorNormalization.normalized(a), let nb = MLVectorNormalization.normalized(b) else {
            return 0
        }
        return zip(na, nb).reduce(0) { $0 + $1.0 * $1.1 }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_TINYCLIP_MODEL"] != nil))
    func optionalCrossLingualTextAlignment() async throws {
        let modelPath = try #require(ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_TINYCLIP_MODEL"])
        let descriptor = MLModelDescriptor(identifier: "tinyclip-39m", version: 1, embeddingDimension: 512)
        let encoder = try await CoreMLDualEncoder(
            modelURL: URL(fileURLWithPath: modelPath),
            descriptor: descriptor,
            imageSource: EmptyImageSource(),
            tokenizer: CLIPBPETokenizer.bundledTinyCLIP()
        )

        var englishEmbeddings: [String: ContiguousArray<Float32>] = [:]
        for entry in Self.concepts {
            englishEmbeddings[entry.concept] = try await encoder.encode(text: entry.english, descriptor: descriptor)
        }

        var aligned = 0
        var report: [String] = []
        for entry in Self.concepts {
            let germanEmbedding = try await encoder.encode(text: entry.german, descriptor: descriptor)
            let ranked = Self.concepts
                .map { ($0.concept, normalizedDot(germanEmbedding, englishEmbeddings[$0.concept]!)) }
                .sorted { $0.1 > $1.1 }
            let top = ranked[0]
            if top.0 == entry.concept { aligned += 1 }
            report.append(
                "\(entry.german) → \(ranked.map { "\($0.0)=\(String(format: "%.3f", $0.1))" }.joined(separator: " "))")
        }
        // Print the alignment matrix for diagnostics.
        print(
            "[tinyclip-quality] cross-lingual alignment \(aligned)/\(Self.concepts.count)\n"
                + report.joined(separator: "\n"))
        // Report partial German alignment, but fail when no German query aligns.
        #expect(
            aligned >= 2,
            "German queries barely align with English concepts (\(aligned)/4); do not claim German support")
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_TINYCLIP_MODEL"] != nil
                && ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_ML_REFERENCE_CORPUS"] != nil))
    func optionalRealPhotoCorpusRanking() async throws {
        let modelPath = try #require(ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_TINYCLIP_MODEL"])
        let corpusPath = try #require(ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_ML_REFERENCE_CORPUS"])
        let corpusURL = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: corpusURL, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        try #require(!files.isEmpty, "reference corpus directory is empty")

        var urlsByUID: [PhotoUID: URL] = [:]
        var conceptByUID: [PhotoUID: String] = [:]
        for file in files {
            guard let concept = Self.concepts.first(where: { file.lastPathComponent.hasPrefix($0.concept) })?.concept
            else { continue }
            let uid = PhotoUID(volumeID: "ref", nodeID: file.lastPathComponent)
            urlsByUID[uid] = file
            conceptByUID[uid] = concept
        }
        try #require(
            Set(conceptByUID.values).count == Self.concepts.count,
            "corpus must contain at least one photo per concept: \(Self.concepts.map(\.concept))")

        let descriptor = MLModelDescriptor(identifier: "tinyclip-39m", version: 1, embeddingDimension: 512)
        let encoder = try await CoreMLDualEncoder(
            modelURL: URL(fileURLWithPath: modelPath),
            descriptor: descriptor,
            imageSource: FileImageSource(urlsByUID: urlsByUID),
            tokenizer: CLIPBPETokenizer.bundledTinyCLIP()
        )

        var block = MLVectorBlock(descriptor: descriptor)
        for uid in urlsByUID.keys.sorted(by: { $0.nodeID < $1.nodeID }) {
            guard case .embedded(let vector) = await encoder.embed(uid: uid, descriptor: descriptor),
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
        for entry in Self.concepts {
            for (label, query, isEnglish) in [("en", entry.english, true), ("de", entry.german, false)] {
                let raw = try await encoder.encode(text: query, descriptor: descriptor)
                guard let normalized = MLVectorNormalization.normalized(raw) else { continue }
                let results = scorer.rank(block: block, query: normalized, limit: 3, queryText: query)
                let topConcept = results.results.first.flatMap { conceptByUID[$0.uid] } ?? "-"
                let hit = topConcept == entry.concept
                if hit { if isEnglish { englishHits += 1 } else { germanHits += 1 } }
                report.append("[\(label)] \(query) → top1=\(topConcept) \(hit ? "HIT" : "MISS")")
            }
        }
        print(
            "[tinyclip-quality] corpus ranking en=\(englishHits)/\(Self.concepts.count) de=\(germanHits)/\(Self.concepts.count)\n"
                + report.joined(separator: "\n"))
        // The English hit floor detects a broken text or image encoding pipeline.
        #expect(englishHits >= Self.concepts.count * 3 / 4)
        // German results remain diagnostic because this model does not guarantee multilingual quality.
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_TINYCLIP_MODEL"] != nil
                && ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_ML_HORSE_CORPUS"] != nil))
    func optionalProductionHorseQueryScoreDistribution() async throws {
        let modelPath = try #require(ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_TINYCLIP_MODEL"])
        let corpusPath = try #require(ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_ML_HORSE_CORPUS"])
        let files = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: corpusPath, isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        let positives = files.filter { $0.lastPathComponent.hasPrefix("positive-") }
        let negatives = files.filter { $0.lastPathComponent.hasPrefix("negative-") }
        try #require(!positives.isEmpty && !negatives.isEmpty, "corpus needs positive-* and negative-* images")

        let descriptor = MLModelCatalogEntry.tinyCLIPVit40M.descriptor
        var urlsByUID: [PhotoUID: URL] = [:]
        var positiveUIDs = Set<PhotoUID>()
        for file in positives + negatives {
            let uid = PhotoUID(volumeID: "horse-calibration", nodeID: file.lastPathComponent)
            urlsByUID[uid] = file
            if file.lastPathComponent.hasPrefix("positive-") { positiveUIDs.insert(uid) }
        }
        let encoder = try await CoreMLDualEncoder(
            modelURL: URL(fileURLWithPath: modelPath),
            descriptor: descriptor,
            imageSource: FileImageSource(urlsByUID: urlsByUID),
            tokenizer: CLIPBPETokenizer.bundledTinyCLIP()
        )
        var block = MLVectorBlock(descriptor: descriptor)
        for uid in urlsByUID.keys.sorted(by: { $0.nodeID < $1.nodeID }) {
            guard case .embedded(let vector) = await encoder.embed(uid: uid, descriptor: descriptor),
                let normalized = MLVectorNormalization.normalized(vector)
            else {
                Issue.record("failed to embed calibration image \(uid.nodeID)")
                continue
            }
            block.append(uid: uid, vector: normalized)
        }
        #expect(block.count == urlsByUID.count)

        let scorer = AccelerateVectorScorer()
        for query in ["horse", "Pferd", "elephant"] {
            let raw = try await encoder.encode(text: query, descriptor: descriptor)
            let normalized = try #require(MLVectorNormalization.normalized(raw))
            let results = scorer.rank(block: block, query: normalized, limit: block.count, queryText: query).results
            let relevantResults = MLModelCatalogEntry.tinyCLIPVit40M.relevancePolicy.relevantResults(from: results)
            let topPositiveRank = try #require(results.firstIndex { positiveUIDs.contains($0.uid) }).advanced(by: 1)
            let topTwelvePositiveCount = results.prefix(12).count { positiveUIDs.contains($0.uid) }
            print(
                "[tinyclip-horse] \(query) topPositiveRank=\(topPositiveRank) "
                    + "top12Positives=\(topTwelvePositiveCount) relevant=\(relevantResults.count)\n"
                    + results.prefix(20).enumerated().map {
                        "\($0.offset + 1). \($0.element.uid.nodeID) \($0.element.score)"
                    }.joined(separator: "\n")
            )
            if query == "horse" {
                #expect(topPositiveRank == 1)
                #expect(topTwelvePositiveCount >= 8)
                #expect(relevantResults.count == positiveUIDs.count)
                #expect(relevantResults.allSatisfy { positiveUIDs.contains($0.uid) })
            } else if query == "Pferd" {
                #expect(relevantResults.count >= 12)
                #expect(relevantResults.allSatisfy { positiveUIDs.contains($0.uid) })
            } else if query == "elephant" {
                #expect(relevantResults.isEmpty)
            }
        }
    }
}
