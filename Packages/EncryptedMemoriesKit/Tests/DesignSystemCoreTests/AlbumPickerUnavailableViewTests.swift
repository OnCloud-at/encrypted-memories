import PhotosCore
import SwiftUI
import Testing

@testable import DesignSystemCore

@Suite struct AlbumPickerUnavailableViewTests {
    @Test func noAlbumsUsesTheExistingAlbumChooserCopy() {
        #expect(AlbumPickerUnavailableView.noAlbumsTitle == L10n.string("albums.none_available"))
        #expect(AlbumPickerUnavailableView.noAlbumsTitle != "albums.none_available")
    }

    @MainActor @Test func noAlbumsDrawsTheNativeEmptyAlbumState() throws {
        let shared = try RenderedInk.pixels(AlbumPickerUnavailableView())
        let native = try RenderedInk.pixels(
            ContentUnavailableView(L10n.string("albums.none_available"), systemImage: "rectangle.stack"))
        #expect(shared > 100)
        #expect(shared == native)
    }

    @MainActor @Test func noMatchesDrawsTheNativeSearchStateWithItsQuery() throws {
        let query = "No matching album"
        let shared = try RenderedInk.pixels(AlbumPickerUnavailableView(searchText: query))
        let native = try RenderedInk.pixels(ContentUnavailableView.search(text: query))
        #expect(shared > 100)
        #expect(shared == native)
    }

    @MainActor @Test func deniedAccessDrawsTheMessageSuppliedByThePlatform() throws {
        let message = "Photos permission is missing in the platform settings."
        let shared = try RenderedInk.pixels(AlbumPickerUnavailableView(accessDeniedMessage: message))
        let native = try RenderedInk.pixels(ContentUnavailableView(message, systemImage: "lock.rectangle.stack"))
        #expect(shared > 100)
        #expect(shared == native)
    }
}
