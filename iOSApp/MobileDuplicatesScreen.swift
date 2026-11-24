import DesignSystemCore
import MediaCacheUIKitAdapter
import PhotoViewerCore
import PhotosCore
import SwiftUI
import UploadCore
import UploadFeature

/// The Duplicates screen on iPhone and iPad: the shared `ExactDuplicatesView` with the Merge All toolbar button. A tap
/// on a photo opens the shared viewer with the photos of its group and the merge tools. The row of a review list, such
/// as the copies whose details differ, pushes `MobileReviewDuplicatesScreen`.
struct MobileDuplicatesScreen: View {
    let model: ExactDuplicatesModel
    /// The shared thumbnail feed of the library. The thumbnails come from its bounded decoded tier.
    let feed: UIKitThumbnailFeed?
    @Environment(MobileLibraryModel.self) private var libraryModel
    @Environment(MobileViewerRouter.self) private var viewerRouter
    @State private var confirmsMergeAll = false
    @State private var route = ExactDuplicatesRoute()

    /// Three copies side by side fit an iPhone list row; a larger group scrolls. Both lists use them.
    static let thumbnailSide: CGFloat = 104
    static let cornerRadius: CGFloat = 10

    var body: some View {
        // Read in the body, so a list closes when its last group left, for example after the person deleted a copy.
        let shown = ExactDuplicateReviewList.allCases.first { route.shows($0, of: model) }
        let emptyLists = ExactDuplicateReviewList.allCases.map { model.reviewGroups($0).isEmpty }
        ExactDuplicatesView(
            model: model, confirmsMergeAll: $confirmsMergeAll, accent: ProtonColor.primary,
            cornerRadius: Self.cornerRadius, canOpen: { libraryModel.snapshot.item(for: $0) != nil },
            onOpen: { openPhoto($0, groupID: $1) }, onShowReview: { route.show($0, of: model) },
            isCoveredByReview: shown != nil
        ) { uid in
            ExactDuplicateThumbnail(
                uid: uid, side: Self.thumbnailSide, cornerRadius: Self.cornerRadius, thumbnails: thumbnails)
        }
        .mobileNavigationTitle(L10n.string("duplicates.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.string("duplicates.merge_all")) { confirmsMergeAll = true }
                    .disabled(!model.canMerge)
                    .accessibilityIdentifier("duplicates.mergeAll")
            }
        }
        .navigationDestination(item: Binding(get: { shown }, set: { if $0 == nil { route.back() } })) { list in
            MobileReviewDuplicatesScreen(model: model, list: list, feed: feed)
        }
        .onChange(of: emptyLists) { route.follow(model) }
    }

    private var thumbnails: ExactDuplicateThumbnails {
        ExactDuplicateThumbnails(feedCore: feed?.feedCore)
    }

    /// Opens `uid` with the other photos of its group that the library shows.
    private func openPhoto(_ uid: PhotoUID, groupID: String) {
        let snapshot = libraryModel.snapshot
        guard let opened = model.viewerItems(opening: uid, inGroup: groupID, item: { snapshot.item(for: $0) })
        else { return }
        viewerRouter.presentation = MobileViewerPresentation(
            index: opened.index, items: opened.items, context: .library,
            duplicateGroup: MobileDuplicateViewerGroup(model: model))
    }
}

/// A review list on iPhone and iPad, such as the copies with the same bytes whose details differ. A tap on a copy
/// opens the library viewer with the copies of its group, with Move to Trash and without merge tools.
struct MobileReviewDuplicatesScreen: View {
    let model: ExactDuplicatesModel
    let list: ExactDuplicateReviewList
    let feed: UIKitThumbnailFeed?
    @Environment(MobileLibraryModel.self) private var libraryModel
    @Environment(MobileViewerRouter.self) private var viewerRouter

    var body: some View {
        let snapshot = libraryModel.snapshot
        ExactDuplicatesReviewView(
            model: model, list: list, item: { snapshot.item(for: $0) }, onOpen: { openPhoto($0, groupID: $1) }
        ) { uid in
            ExactDuplicateThumbnail(
                uid: uid, side: MobileDuplicatesScreen.thumbnailSide,
                cornerRadius: MobileDuplicatesScreen.cornerRadius,
                thumbnails: ExactDuplicateThumbnails(feedCore: feed?.feedCore))
        }
        .mobileNavigationTitle(list.title)
    }

    private func openPhoto(_ uid: PhotoUID, groupID: String) {
        let snapshot = libraryModel.snapshot
        guard
            let opened = model.viewerItems(
                opening: uid, in: list, groupID: groupID, item: { snapshot.item(for: $0) })
        else { return }
        viewerRouter.presentation = MobileViewerPresentation(
            index: opened.index, items: opened.items, context: .library)
    }
}
