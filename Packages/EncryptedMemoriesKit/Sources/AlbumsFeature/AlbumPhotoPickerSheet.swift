import AlbumCore
import DesignSystemCore
import PhotosCore
import SwiftUI

/// The sheet that adds library photos to an owned album, shared by macOS, iOS and iPadOS. Each platform supplies
/// only its native photo grid; states, toolbar, failures and the add live here once.
public struct AlbumPhotoPickerSheet<Grid: View>: View {
    @Bindable private var model: AlbumPhotoPickerModel
    private let onRetry: () -> Void
    private let onAlbumChanged: () -> Void
    private let grid: (AlbumPhotoPickerModel) -> Grid
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// - Parameters:
    ///   - onRetry: Loads the library again after a failure.
    ///   - onAlbumChanged: Runs after an add that changed the album: a full add, before the sheet closes, or a
    ///     partial one, while the sheet stays open with its selection.
    ///   - grid: The platform grid of `model.candidates` in selection mode.
    public init(
        model: AlbumPhotoPickerModel,
        onRetry: @escaping () -> Void,
        onAlbumChanged: @escaping () -> Void,
        @ViewBuilder grid: @escaping (AlbumPhotoPickerModel) -> Grid
    ) {
        self.model = model
        self.onRetry = onRetry
        self.onAlbumChanged = onAlbumChanged
        self.grid = grid
    }

    public var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(L10n.string("albums.add_photos_title"))
                // The count goes below the title; a title of the count alone was cut off in German. A macOS sheet shows
                // both above its content too.
                .navigationSubtitle(selectionCount)
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            cancelLabel
                        }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.coordinator.isWorking)
                    }
                    ProminentToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await add() }
                        } label: {
                            Label(L10n.string("albums.add_photos_confirm"), systemImage: "plus").textBarItem()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canSubmit)
                    }
                }
                .overlay {
                    if model.coordinator.isWorking { ProgressSpinner() }
                }
        }
        // The add cannot be stopped halfway. Swiping the sheet away asks nothing first; the selection is not kept.
        .interactiveDismissDisabled(model.coordinator.isWorking)
        #if os(macOS)
            .frame(minWidth: 480, idealWidth: 720, minHeight: 360, idealHeight: 560)
        #else
            .presentationSizing(.page)
            .presentationDetents([.large])
        #endif
        .albumActionFailureAlert(model.coordinator)
    }

    /// A compact iPhone shows only the close symbol, the iOS 26 look of a sheet's Cancel, so the title and the count
    /// fit next to Add in German too. VoiceOver still reads "Cancel".
    @ViewBuilder private var cancelLabel: some View {
        let label = Label(L10n.string("action.cancel"), systemImage: "xmark")
        #if os(iOS)
            if horizontalSizeClass == .compact {
                label.labelStyle(.iconOnly)
            } else {
                label.textBarItem()
            }
        #else
            label.textBarItem()
        #endif
    }

    private var selectionCount: String {
        model.selection.isEmpty ? "" : L10n.selectionCenterText(selectedCount: model.selection.count)
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .loading:
            GridLoadingMark()
        case .failed(let message, let retryable):
            LibraryLoadErrorView(message: message, retryable: retryable, onRetry: onRetry)
        case .emptyLibrary:
            ContentUnavailableView(L10n.string("empty.no_photos_title"), systemImage: "photo.on.rectangle")
        case .nothingToAdd:
            ContentUnavailableView(
                L10n.string("albums.add_photos_empty_title"),
                systemImage: "checkmark.rectangle.stack",
                description: Text(L10n.string("albums.add_photos_empty_message"))
            )
        case .choose:
            grid(model)
        }
    }

    private func add() async {
        switch await model.submit() {
        case .added:
            onAlbumChanged()
            dismiss()
        case .failed:
            // Some photos may have joined the album before the failure.
            onAlbumChanged()
        case .notStarted:
            break
        }
    }
}
