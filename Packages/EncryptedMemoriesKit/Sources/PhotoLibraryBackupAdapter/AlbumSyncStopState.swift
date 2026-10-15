import AlbumSyncCore
import Foundation
import PhotosCore

/// Whether the person pressed Stop during the current Album Sync batch, and what the message line says after it.
/// The controller only reports the events; this type decides, so both native hosts show the same result.
struct AlbumSyncStopState: Equatable {
    /// How the run of one album ended.
    enum Outcome {
        case finished(AlbumSyncReport)
        case stopped
        /// The album backup reports a Stop as cancellation.
        case cancelled
    }

    struct Message: Equatable {
        var text: String?
        var style: AlbumSyncController.MessageStyle
    }

    private(set) var isRequested = false
    /// Stop removed albums that were still waiting in the batch.
    private(set) var droppedQueuedAlbums = false

    mutating func batchStarted() {
        isRequested = false
        droppedQueuedAlbums = false
    }

    mutating func stopPressed(isSyncing: Bool, queuedAlbums: Int) {
        guard isSyncing else { return }
        isRequested = true
        if queuedAlbums > 0 { droppedQueuedAlbums = true }
    }

    /// An album joins the running batch after Stop, for example from the name-conflict dialog. Its run is not stopped,
    /// so the Stop no longer applies. Returns true when the stop text should clear.
    mutating func albumAdded() -> Bool {
        guard isRequested else { return false }
        batchStarted()
        return true
    }

    /// A Stop reported as cancellation ends the run like `.stopped`; without a Stop it stays an error.
    func endsAsStop(_ error: any Error) -> Bool {
        isRequested && error is CancellationError
    }

    /// The new message line after `outcome`, or `nil` to keep the line. A real error stays. A run that ended with
    /// photos that need attention adds nothing, because the album row says so.
    func message(after outcome: Outcome, current: Message) -> Message? {
        guard isRequested else { return nil }
        if current.text != nil, current.style == .error { return nil }
        let stopped = Message(text: L10n.string("albumsync.error_stopped"), style: .information)
        switch outcome {
        case .stopped, .cancelled:
            return stopped
        case .finished(let report):
            if droppedQueuedAlbums { return stopped }
            return report.isFullySynced
                ? Message(text: L10n.string("albumsync.phase_completed"), style: .information) : nil
        }
    }
}
