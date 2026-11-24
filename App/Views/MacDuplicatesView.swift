import DesignSystemCore
import MediaCache
import PhotosCore
import SwiftUI
import UploadCore
import UploadFeature

/// The Duplicates route on macOS: the shared `ExactDuplicatesView` under the window toolbar, or with `shownReview`
/// the shared `ExactDuplicatesReviewView` of that list. The toolbar owns the Merge All and Back buttons and sets
/// `confirmsMergeAll`; a click on a photo opens it in the viewer with its group or with the copies of its review group.
struct MacDuplicatesView: View {
    let model: ExactDuplicatesModel
    let thumbnailFeed: ThumbnailFeed
    /// The height of the window toolbar that floats over this view.
    let topInset: CGFloat
    @Binding var confirmsMergeAll: Bool
    /// The photo once the library shows it, so the viewer can open it.
    let item: (PhotoUID) -> PhotoItem?
    /// Changes when the library shows other photos; `item` reads a library that is not observed.
    let libraryRevision: UInt64
    /// The review list that shows instead of the duplicates, such as the copies whose details differ.
    let shownReview: ExactDuplicateReviewList?
    /// Opens a photo and the ID of its group in the viewer.
    let onOpen: (PhotoUID, String) -> Void
    let onShowReview: (ExactDuplicateReviewList) -> Void
    /// Opens a copy of a review list and the ID of its group in the viewer.
    let onOpenReview: (ExactDuplicateReviewList, PhotoUID, String) -> Void

    /// A fixed, comfortable thumbnail size: a wide window adds margins, not larger photos.
    private static let thumbnailSide: CGFloat = 132
    private static let cornerRadius: CGFloat = 6

    /// The thumbnails come from the bounded decoded tier of the shared feed; the screen keeps none of its own.
    private var thumbnails: ExactDuplicateThumbnails {
        ExactDuplicateThumbnails(feedCore: thumbnailFeed.feedCore)
    }

    private func cover(_ uid: PhotoUID) -> ExactDuplicateThumbnail {
        ExactDuplicateThumbnail(
            uid: uid, side: Self.thumbnailSide, cornerRadius: Self.cornerRadius, thumbnails: thumbnails)
    }

    var body: some View {
        // The duplicates stay under a review list, so their load and check go on and Back reads nothing again.
        let covered = shownReview != nil
        ZStack {
            ExactDuplicatesView(
                model: model, confirmsMergeAll: $confirmsMergeAll, accent: .accentColor,
                cornerRadius: Self.cornerRadius, canOpen: { item($0) != nil }, libraryRevision: libraryRevision,
                onOpen: onOpen, onShowReview: onShowReview, isCoveredByReview: covered, cover: cover
            )
            .opacity(covered ? 0 : 1)
            .allowsHitTesting(!covered)
            // No keyboard focus either; the load and check of the screen go on.
            .disabled(covered)
            .accessibilityHidden(covered)
            if let list = shownReview {
                ExactDuplicatesReviewView(
                    model: model, list: list, item: item, libraryRevision: libraryRevision,
                    onOpen: { onOpenReview(list, $0, $1) }, cover: cover)
            }
        }
        .contentMargins(.top, topInset, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
    }
}
