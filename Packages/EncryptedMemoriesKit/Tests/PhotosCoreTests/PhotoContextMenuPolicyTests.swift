import PhotosCore
import Testing

@Suite struct PhotoContextMenuPolicyTests {
    @Test func libraryMenuOffersExistingActionsAndFavoriteState() {
        let actions = PhotoContextMenuPolicy.actions(
            itemCount: 1, isTrash: false, canMutate: true, canFavorite: true,
            allFavorited: true, canAddToAlbum: true, canRemoveFromAlbum: false)
        #expect(actions == [.copy, .share, .unfavorite, .addToAlbum, .information, .trash])
        #expect(actions.allSatisfy { !$0.title.isEmpty && !$0.title.contains("viewer.") })
    }

    @Test func trashRestoresAndDoesNotOfferLibraryMutations() {
        #expect(
            PhotoContextMenuPolicy.actions(
                itemCount: 1, isTrash: true, canMutate: true, canFavorite: true,
                allFavorited: false, canAddToAlbum: true, canRemoveFromAlbum: true)
                == [.copy, .share, .information, .restore])
    }

    @Test func multiItemAndUnavailableMutationsAreTruthful() {
        #expect(
            PhotoContextMenuPolicy.actions(
                itemCount: 2, isTrash: false, canMutate: false, canFavorite: true,
                allFavorited: false, canAddToAlbum: true, canRemoveFromAlbum: true) == [.copy, .share])
        #expect(
            PhotoContextMenuPolicy.actions(
                itemCount: 2, isTrash: false, canMutate: true, canFavorite: false,
                allFavorited: false, canAddToAlbum: false, canRemoveFromAlbum: true)
                == [.copy, .share, .removeFromAlbum, .trash])
    }
}
