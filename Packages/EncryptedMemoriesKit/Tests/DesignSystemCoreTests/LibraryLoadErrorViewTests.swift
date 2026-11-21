import PhotosCore
import SwiftUI
import Testing

@testable import DesignSystemCore

@Suite struct LibraryLoadErrorViewTests {
    /// The view draws exactly what the same screen with this platform's symbol draws, and not the other platform's.
    @MainActor @Test func theViewDrawsThisPlatformsSymbol() throws {
        func reference(_ symbol: String) throws -> Int {
            try RenderedInk.pixels(
                ContentUnavailableView {
                    Label(L10n.string("error.load_library_title"), systemImage: symbol)
                } description: {
                    Text("Offline")
                })
        }
        let drawn = try RenderedInk.pixels(LibraryLoadErrorView(message: "Offline", retryable: false, onRetry: {}))
        let triangle = try reference("exclamationmark.triangle")
        let cloud = try reference("exclamationmark.icloud")
        #expect(triangle != cloud, "the two symbols draw differently")
        #if os(macOS)
            #expect(drawn == triangle, "the Mac keeps its library symbol")
        #else
            #expect(drawn == cloud, "iPhone and iPad keep their library symbol")
        #endif
    }
}
