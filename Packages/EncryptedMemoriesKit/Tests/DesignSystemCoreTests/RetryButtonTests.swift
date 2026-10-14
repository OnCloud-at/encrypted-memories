import PhotosCore
import Testing

@testable import DesignSystemCore

@Suite struct RetryButtonTests {
    @Test func everyRetryStyleReadsTheOneSharedTitle() {
        #expect(RetryButton.title == L10n.string("action.retry"))
        #expect(!RetryButton.title.isEmpty)
    }
}
