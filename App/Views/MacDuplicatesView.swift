import DesignSystemCore
import MediaCache
import PhotosCore
import SwiftUI
import UploadCore
import UploadFeature

/// The Duplicates route on macOS: the shared `ExactDuplicatesView` under the window toolbar. The toolbar owns the
/// Merge All button and sets `confirmsMergeAll`; a click on a photo opens it in the viewer with its group.
struct MacDuplicatesView: View {
    let model: ExactDuplicatesModel
    let thumbnailFeed: ThumbnailFeed
    let sourceAnalysisRevision: UInt64
    /// The height of the window toolbar that floats over this view.
    let topInset: CGFloat
    @Binding var confirmsMergeAll: Bool
    /// Opens a photo and the ID of its group in the viewer.
    let onOpen: (PhotoUID, String) -> Void

    /// A fixed, comfortable thumbnail size: a wide window adds margins, not larger photos.
    private static let thumbnailSide: CGFloat = 132
    private static let cornerRadius: CGFloat = 6

    var body: some View {
        ExactDuplicatesView(
            model: model, confirmsMergeAll: $confirmsMergeAll, accent: .accentColor, cornerRadius: Self.cornerRadius,
            onOpen: onOpen
        ) { uid in
            AlbumSidebarCover(
                coverUID: uid, fallbackSystemImage: "photo", thumbnailFeed: thumbnailFeed,
                sourceAnalysisRevision: sourceAnalysisRevision, size: Self.thumbnailSide
            )
        }
        .contentMargins(.top, topInset, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
    }
}
