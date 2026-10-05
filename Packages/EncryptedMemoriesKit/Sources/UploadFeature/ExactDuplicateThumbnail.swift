import PhotosCore
import SwiftUI

/// The thumbnails of the Duplicates screen, read through the host's shared thumbnail feed on every platform.
///
/// The feed owns the images: its decoded tier holds them at the display size of the grid, within a bounded budget
/// that shrinks under memory pressure. A tile reads from that tier when it draws and keeps no image of its own, so
/// 1,500 groups cost no more memory than the photos on screen. A tile that finds none loads it into the tier while
/// it is on screen (`ThumbnailFeedCore.visibleDecoded`).
public struct ExactDuplicateThumbnails {
    /// Reads the image of a photo from the shared tier, without loading it. Nil while the tier has none.
    let read: @MainActor (PhotoUID) -> Image?
    /// Loads the image of a photo into the shared tier, until it exists or the task is cancelled.
    let load: @MainActor (PhotoUID) async -> Void

    public init(
        read: @escaping @MainActor (PhotoUID) -> Image?, load: @escaping @MainActor (PhotoUID) async -> Void
    ) {
        self.read = read
        self.load = load
    }
}

/// One square thumbnail of the Duplicates screen. It draws the image that the shared tier holds now, and loads it
/// while it is on screen; leaving the screen cancels its load.
public struct ExactDuplicateThumbnail: View {
    private let uid: PhotoUID
    private let side: CGFloat
    private let cornerRadius: CGFloat
    private let thumbnails: ExactDuplicateThumbnails
    /// Counts the loads of this tile, so it draws again after one. It holds no image.
    @State private var loads = 0

    public init(uid: PhotoUID, side: CGFloat, cornerRadius: CGFloat, thumbnails: ExactDuplicateThumbnails) {
        self.uid = uid
        self.side = side
        self.cornerRadius = cornerRadius
        self.thumbnails = thumbnails
    }

    public var body: some View {
        _ = loads
        let image = thumbnails.read(uid)
        return ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: uid) {
            guard thumbnails.read(uid) == nil else { return }
            await thumbnails.load(uid)
            guard !Task.isCancelled else { return }
            loads &+= 1
        }
    }
}
