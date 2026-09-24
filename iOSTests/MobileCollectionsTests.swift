import PhotosCore
import Testing

@testable import EncryptedMemoriesMobile

/// Collections on iPhone and iPad offer the same server-backed smart filters as the Mac sidebar.
@Suite struct MobileCollectionsTests {
    @Test func smartCategoriesMatchTheMacSidebar() {
        #expect(MobileCollectionsScreen.smartCategories == PhotoTag.allCases)
    }

    @Test func smartCategoriesKeepFavoritesFirst() {
        #expect(MobileCollectionsScreen.smartCategories.first == .favorites)
    }
}
