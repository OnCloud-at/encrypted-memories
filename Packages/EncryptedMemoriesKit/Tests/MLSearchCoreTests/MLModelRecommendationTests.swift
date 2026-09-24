import Foundation
import Testing

@testable import MLSearchCore

@Suite struct MLModelRecommendationTests {
    private let small = MLModelRecommendationTests.entry(id: "small-english", bytes: 100, languages: .englishOnly)
    private let large = MLModelRecommendationTests.entry(id: "large-multilingual", bytes: 800, languages: .multilingual)

    @Test func englishDeviceGetsTheSmallestModel() {
        let recommended = MLModelRecommendation.recommendedModel(among: [large, small], preferredLanguages: ["en-US"])
        #expect(recommended?.id == small.id)
    }

    @Test func otherLanguagesGetAModelThatUnderstandsThem() {
        for language in ["de-AT", "fr", "ja-JP", "pt-BR"] {
            let recommended = MLModelRecommendation.recommendedModel(
                among: [small, large], preferredLanguages: [language])
            #expect(recommended?.id == large.id, "\(language)")
        }
    }

    @Test func onlyTheFirstPreferredLanguageCounts() {
        let recommended = MLModelRecommendation.recommendedModel(
            among: [small, large], preferredLanguages: ["de-DE", "en-US"])
        #expect(recommended?.id == large.id)
    }

    @Test func withoutAMultilingualModelTheSmallestIsRecommended() {
        let other = entry(id: "larger-english", bytes: 300, languages: .englishOnly)
        let recommended = MLModelRecommendation.recommendedModel(among: [other, small], preferredLanguages: ["de"])
        #expect(recommended?.id == small.id)
    }

    @Test func withoutAPreferredLanguageTheMultilingualModelIsRecommended() {
        #expect(MLModelRecommendation.recommendedModel(among: [small, large], preferredLanguages: [])?.id == large.id)
    }

    @Test func recommendedModelComesFirstAndTheRestKeepCatalogOrder() {
        let middle = entry(id: "middle", bytes: 500, languages: .englishOnly)
        let ordered = MLModelRecommendation.ordered([small, middle, large], preferredLanguages: ["de"])
        #expect(ordered.map(\.id) == [large.id, small.id, middle.id])
        #expect(MLModelRecommendation.ordered([], preferredLanguages: ["de"]).isEmpty)
    }

    @Test func shippedModelsDeclareTheirSearchLanguages() {
        #expect(MLModelCatalogEntry.tinyCLIPVit40M.localizedMetadata.queryLanguages == .englishOnly)
        #expect(MLModelCatalogEntry.sigLIP2Base256.localizedMetadata.queryLanguages == .multilingual)
    }

    private static func entry(id: String, bytes: Int64, languages: MLModelQueryLanguages) -> MLModelCatalogEntry {
        MLModelCatalogEntry(
            id: MLModelID(id),
            displayName: id,
            family: "Test",
            descriptor: MLModelDescriptor(identifier: id, version: 1, embeddingDimension: 4),
            tokenizerID: "test-tokenizer",
            preprocessingID: "test-preprocessing",
            license: .mit,
            releaseTrack: .production,
            localizedMetadata: .init(
                selectionTitleKey: "title", selectionDescriptionKey: "description", queryLanguages: languages),
            estimatedInstalledBytes: bytes,
            downloadPlan: nil
        )
    }

    private func entry(id: String, bytes: Int64, languages: MLModelQueryLanguages) -> MLModelCatalogEntry {
        Self.entry(id: id, bytes: bytes, languages: languages)
    }
}
