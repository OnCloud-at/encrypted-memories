import AlbumsFeature
import DesignSystemCore
import MediaCache
import PhotosCore
import SwiftUI
import TimelineCore
import TimelineFeature

/// The Mac grid of the album photo picker: the production timeline grid on a model of its own, so the album grid
/// underneath keeps its route, selection and scroll position.
struct MacAlbumPhotoPickerGrid: View {
    let picker: AlbumPhotoPickerModel
    let feed: ThumbnailFeed
    let uploadBadges: PendingUploadBadges
    /// Makes the grid's model; it runs once, when the grid appears.
    let makeGridModel: () -> TimelineViewModel
    @State private var gridModel: TimelineViewModel?
    @State private var level = TimelineGridProfiles.productionDefaultProfile.defaultLevel

    var body: some View {
        Group {
            if let gridModel {
                TimelineView(
                    model: gridModel,
                    feed: feed,
                    level: $level,
                    selectionMode: true,
                    onSelectionChange: { picker.replaceSelection(with: $0) }
                )
            } else {
                GridLoadingMark()
            }
        }
        .task {
            let model = gridModel ?? makeGridModel()
            gridModel = model
            await model.showTransientItems(
                picker.candidates, sectionID: "album-add-photos", uploadBadges: uploadBadges,
                restartsPrefetch: false)
        }
        // Photos that are still backing up keep showing their current upload state while the sheet is open.
        .onChange(of: uploadBadges) { _, badges in gridModel?.updateTransientUploadBadges(badges) }
    }
}
