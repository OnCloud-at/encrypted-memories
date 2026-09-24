import Foundation

/// Chooses the model that suits the device language. People who use English get the smallest model;
/// everyone else gets the smallest model that understands searches in their language.
public enum MLModelRecommendation {
    public static func recommendedModel(
        among models: [MLModelCatalogEntry],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> MLModelCatalogEntry? {
        let smallestFirst = models.sorted { downloadSize($0) < downloadSize($1) }
        guard !usesEnglish(preferredLanguages) else { return smallestFirst.first }
        return smallestFirst.first { $0.localizedMetadata.queryLanguages == .multilingual } ?? smallestFirst.first
    }

    /// The recommended model first, then the others in catalog order.
    public static func ordered(
        _ models: [MLModelCatalogEntry],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [MLModelCatalogEntry] {
        guard let recommended = recommendedModel(among: models, preferredLanguages: preferredLanguages) else {
            return models
        }
        return [recommended] + models.filter { $0.id != recommended.id }
    }

    /// Only the first preferred language counts; it is the language the person types in. Without
    /// any preference the choice falls to a model that also understands English.
    static func usesEnglish(_ preferredLanguages: [String]) -> Bool {
        guard let primary = preferredLanguages.first else { return false }
        return Locale(identifier: primary).language.languageCode == .english
    }

    private static func downloadSize(_ model: MLModelCatalogEntry) -> Int64 {
        model.downloadPlan?.totalByteCount ?? model.estimatedInstalledBytes
    }
}
