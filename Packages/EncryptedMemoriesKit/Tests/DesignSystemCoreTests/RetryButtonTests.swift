import PhotosCore
import Testing

@testable import DesignSystemCore

@Suite struct RetryButtonTests {
    /// Plain SwiftPM builds do not compile the String Catalog; xcodebuild runs this check.
    static var catalogIsCompiled: Bool { L10n.resourceBundle.localizations.contains("de") }

    @Test(.enabled(if: RetryButtonTests.catalogIsCompiled)) func everyRetryStyleReadsTheTranslatedSharedTitle() {
        #expect(RetryButton.title == L10n.string("action.retry"))
        #expect(RetryButton.title != "action.retry", "the title must resolve from the package catalog")
        #expect(!RetryButton.title.isEmpty)
    }
}
