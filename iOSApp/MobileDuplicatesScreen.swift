import DesignSystemCore
import PhotoViewerCore
import PhotosCore
import SwiftUI
import UploadCore
import UploadFeature

/// The Duplicates screen on iPhone and iPad: the shared `ExactDuplicatesView` with the Merge All toolbar button. A tap
/// on a photo opens the shared viewer with the photos of its group and the merge tools.
struct MobileDuplicatesScreen: View {
    let model: ExactDuplicatesModel
    @Environment(MobileLibraryModel.self) private var libraryModel
    @Environment(MobileViewerRouter.self) private var viewerRouter
    @State private var confirmsMergeAll = false

    /// Three copies side by side fit an iPhone list row; a larger group scrolls.
    private static let thumbnailSide: CGFloat = 104
    private static let cornerRadius: CGFloat = 10

    var body: some View {
        ExactDuplicatesView(
            model: model, confirmsMergeAll: $confirmsMergeAll, accent: ProtonColor.primary,
            cornerRadius: Self.cornerRadius, onOpen: { openPhoto($0, groupID: $1) }
        ) { uid in
            MobileAlbumCover(coverUID: uid, fallbackSystemImage: "photo", size: Self.thumbnailSide)
        }
        .mobileNavigationTitle(L10n.string("duplicates.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.string("duplicates.merge_all")) { confirmsMergeAll = true }
                    .disabled(!model.canMerge)
                    .accessibilityIdentifier("duplicates.mergeAll")
            }
        }
    }

    /// Opens `uid` with the other photos of its group that the library shows.
    private func openPhoto(_ uid: PhotoUID, groupID: String) {
        guard let members = model.group(withID: groupID)?.members else { return }
        let items = members.compactMap { libraryModel.snapshot.item(for: $0) }
        guard let index = items.firstIndex(where: { $0.uid == uid }) else { return }
        viewerRouter.presentation = MobileViewerPresentation(
            index: index, items: items, context: .library,
            duplicateGroup: MobileDuplicateViewerGroup(model: model, groupID: groupID))
    }
}
