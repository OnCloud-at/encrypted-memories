import Foundation
import PhotosCore
import UploadCore

/// The one sentence that Album Sync shows for a failure, in its message line and in its progress detail. The text of
/// a system or server error means nothing to the person, so it never reaches the screen.
public enum AlbumSyncFailureMessage {
    /// An album sync cause names itself. So does a cause that only the person can fix (a full Proton storage, a
    /// missing permission): one short sentence would hide what to do. Any other failure gets the short sentence.
    public static func text(for error: any Error) -> String {
        if let typed = error as? AlbumSyncError, let text = typed.errorDescription { return text }
        if let cause = (error as? any FailureClassifiable)?.failureCause,
            // The cause alone decides here; the operation safety does not change the .afterPersonAction rule.
            FailurePolicy.resolve(cause, situation: .awaitedByPerson, safety: .safeRead).retry == .afterPersonAction,
            let text = (error as? any LocalizedError)?.errorDescription
        {
            return text
        }
        return short
    }

    /// "The album could not be synced."
    public static var short: String { L10n.string("albumsync.sync_failed") }
}
