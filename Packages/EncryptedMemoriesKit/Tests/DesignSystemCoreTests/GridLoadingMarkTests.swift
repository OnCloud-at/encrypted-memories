import PhotosCore
import Testing

@testable import DesignSystemCore

@Suite struct GridLoadingMarkTests {
    @Test func voiceOverReadsTheCaptionOrLoading() {
        #expect(GridLoadingMark.accessibilityLabel(nil) == L10n.string("loading.content"))
        #expect(GridLoadingMark.accessibilityLabel("") == L10n.string("loading.content"))
        #expect(GridLoadingMark.accessibilityLabel("Curating library…") == "Curating library…")
    }
}
