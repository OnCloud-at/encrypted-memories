import AlbumCore
import DesignSystemCore
import PhotosCore
import SwiftUI

/// The sheet that adds library photos to an owned album, shared by macOS, iOS and iPadOS. Each platform supplies
/// only its native photo grid; loading, states, toolbar, failures and the add live here once.
public struct AlbumPhotoPickerSheet<Grid: View>: View {
    @Bindable private var model: AlbumPhotoPickerModel
    private let library: (any AlbumPhotoPickerLibrarySource)?
    private let albumItems: [PhotoItem]?
    private let albumRevision: UInt64
    private let onAlbumChanged: () -> Void
    private let grid: (AlbumPhotoPickerModel) -> Grid
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// - Parameters:
    ///   - library: The host's whole library, or nil while the host has none yet.
    ///   - albumItems: The album's own photos, or nil while the album still loads.
    ///   - albumRevision: Changes whenever the album's own photos change.
    ///   - onAlbumChanged: Runs after an add that changed the album: a full add, before the sheet closes, or a
    ///     partial one, while the sheet stays open with its selection.
    ///   - grid: The platform grid of `model.candidates` in selection mode.
    public init(
        model: AlbumPhotoPickerModel,
        library: (any AlbumPhotoPickerLibrarySource)?,
        albumItems: [PhotoItem]?,
        albumRevision: UInt64,
        onAlbumChanged: @escaping () -> Void,
        @ViewBuilder grid: @escaping (AlbumPhotoPickerModel) -> Grid
    ) {
        self.model = model
        self.library = library
        self.albumItems = albumItems
        self.albumRevision = albumRevision
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
        .task(id: library.map { ObjectIdentifier($0) }) { await loadLibrary() }
        .task(id: library.map { model.inputs(from: $0, albumRevision: albumRevision, albumLoaded: albumItems != nil) })
        {
            guard let library else { return }
            await model.update(from: library, albumItems: albumItems)
        }
    }

    private func loadLibrary() async {
        guard let library else { return }
        await model.loadLibrary(from: library)
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
        case .failed(let message):
            LibraryLoadErrorView(message: message, retryable: true) { Task { await loadLibrary() } }
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

extension View {
    /// Presents the Add Photos sheet while `picker` holds a model, and clears it when the sheet closes.
    public func albumPhotoPickerSheet<Grid: View>(
        _ picker: Binding<AlbumPhotoPickerModel?>,
        library: (any AlbumPhotoPickerLibrarySource)?,
        albumItems: [PhotoItem]?,
        albumRevision: UInt64,
        onAlbumChanged: @escaping () -> Void,
        @ViewBuilder grid: @escaping (AlbumPhotoPickerModel) -> Grid
    ) -> some View {
        sheet(
            isPresented: Binding(
                get: { picker.wrappedValue != nil },
                set: { if !$0 { picker.wrappedValue = nil } }
            )
        ) {
            if let model = picker.wrappedValue {
                AlbumPhotoPickerSheet(
                    model: model, library: library, albumItems: albumItems, albumRevision: albumRevision,
                    onAlbumChanged: onAlbumChanged, grid: grid)
            }
        }
    }
}
