import CoreGraphics
import PhotosCore
import SwiftUI
import UploadCore

/// Whether the Backup settings show the "Excluded from Backup" entry. The entry appears as soon as one photo is
/// excluded and stays while the page shows, so the last "Back Up Again" in the list neither removes the entry nor
/// closes the list. A page that shows again starts from the current count.
public struct PendingExcludedPhotosEntryLatch: Equatable, Sendable {
    public private(set) var isShown: Bool

    public init(count: Int = 0) {
        isShown = count > 0
    }

    /// The count changed while the page shows.
    public mutating func update(count: Int) {
        if count > 0 { isShown = true }
    }

    /// The page shows again.
    public mutating func reset(count: Int) {
        isShown = count > 0
    }
}

/// The label of the "Excluded from Backup" entry in the Backup settings of macOS, iOS and iPadOS, with the number
/// of excluded photos.
public struct PendingExcludedPhotosEntryLabel: View {
    private let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        LabeledContent {
            Text(count.formatted())
                .monospacedDigit()
        } label: {
            Text(L10n.string("backup.excluded_title"))
        }
    }
}

/// The list behind the "Excluded from Backup" entry on macOS, iOS and iPadOS. After the last photo went back into
/// the backup, it shows its empty state in place.
public struct PendingExcludedPhotosList: View {
    private let tiles: [PendingTile]
    private let thumbnail: @Sendable (PhotoUID) async -> CGImage?
    private let include: @MainActor (PendingTile) async -> Void

    public init(
        tiles: [PendingTile],
        thumbnail: @escaping @Sendable (PhotoUID) async -> CGImage?,
        include: @escaping @MainActor (PendingTile) async -> Void
    ) {
        self.tiles = tiles
        self.thumbnail = thumbnail
        self.include = include
    }

    public var body: some View {
        Form {
            if !tiles.isEmpty {
                PendingExcludedPhotosSection(tiles: tiles, thumbnail: thumbnail, include: include)
            }
        }
        .formStyle(.grouped)
        .overlay {
            if tiles.isEmpty {
                let copy = PhotoFilterEmptyStateCopy.excludedFromBackup
                ContentUnavailableView(copy.title, systemImage: copy.systemImage, description: Text(copy.description))
            }
        }
    }
}

extension PhotoFilterEmptyStateCopy {
    /// The empty list of photos excluded from the backup.
    public static var excludedFromBackup: PhotoFilterEmptyStateCopy {
        PhotoFilterEmptyStateCopy(
            title: L10n.string("backup.excluded_empty"),
            description: L10n.string("backup.excluded_empty_description"),
            systemImage: "icloud.slash")
    }
}
