import Foundation
import PhotosCore
import Testing

@testable import MLSearchCore

@Suite struct MLSearchConceptDiscoveryTests {
    private let nature = MLSearchConcept(id: "nature", prompt: "a photo of a nature landscape", systemImage: "leaf")
    private let forest = MLSearchConcept(id: "forest", prompt: "a photo of a forest with trees", systemImage: "tree")
    private let dog = MLSearchConcept(id: "dog", prompt: "a photo of a dog", systemImage: "dog")
    private let beach = MLSearchConcept(
        id: "beach", prompt: "a photo of a beach by the sea", systemImage: "beach.umbrella")

    @Test func conceptsNeedEnoughHitsAndSensitiveMatchesNeverCount() async {
        let beachHits = uids("b", 0..<8)
        let sensitive = Set(beachHits.prefix(4))
        let responses: [String: [PhotoUID]] = [
            nature.prompt: uids("n", 0..<10),
            dog.prompt: uids("d", 0..<3),
            beach.prompt: beachHits,
            MLSearchConceptCatalog.sensitivePrompts[0]: Array(sensitive),
        ]

        let result = await MLSearchConceptDiscovery.evaluate(
            concepts: [nature, dog, beach],
            coveredAssetCount: 100
        ) { prompt, _ in responses[prompt] ?? [] }

        #expect(result.evidence.map(\.concept.id) == ["nature"])
        #expect(result.sensitiveUIDs == sensitive)
    }

    @Test func aConceptThatMostlyRepeatsAStrongerConceptIsDropped() async {
        let natureHits = uids("x", 0..<20)
        let responses: [String: [PhotoUID]] = [
            nature.prompt: natureHits,
            forest.prompt: Array(natureHits.prefix(9)) + uids("f", 0..<1),
            dog.prompt: uids("d", 0..<7),
        ]

        let result = await MLSearchConceptDiscovery.evaluate(
            concepts: [forest, nature, dog],
            coveredAssetCount: 100
        ) { prompt, _ in responses[prompt] ?? [] }

        #expect(result.evidence.map(\.concept.id) == ["nature", "dog"])
    }

    @Test func aFailingQuerySkipsOnlyThatConcept() async {
        struct QueryFailure: Error {}
        let result = await MLSearchConceptDiscovery.evaluate(
            concepts: [dog, nature],
            coveredAssetCount: 10
        ) { prompt, _ in
            if prompt == dog.prompt { throw QueryFailure() }
            return prompt == nature.prompt ? uids("n", 0..<6) : []
        }

        #expect(result.evidence.map(\.concept.id) == ["nature"])
    }

    @Test func thresholdScalesWithCoverageAndNeverDropsBelowSix() {
        #expect(MLSearchConceptDiscovery.minimumHits(coveredAssetCount: 0) == 6)
        #expect(MLSearchConceptDiscovery.minimumHits(coveredAssetCount: 1_000) == 6)
        #expect(MLSearchConceptDiscovery.minimumHits(coveredAssetCount: 50_000) == 200)
    }

    @Test func everyCuratedConceptHasAReviewedTitleAndAUniqueID() {
        let ids = MLSearchConceptCatalog.curated.map(\.id)
        #expect(Set(ids).count == ids.count)
        for concept in MLSearchConceptCatalog.curated {
            #expect(concept.title != "search.concept.\(concept.id)", "missing catalog title for \(concept.id)")
            #expect(concept.prompt.hasPrefix("a photo of"))
        }
    }

    private func uids(_ prefix: String, _ range: Range<Int>) -> [PhotoUID] {
        range.map { PhotoUID(volumeID: "v", nodeID: "\(prefix)\($0)") }
    }
}
