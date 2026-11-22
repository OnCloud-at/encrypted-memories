import Foundation
import PhotosCore

/// The failure of registering a folder for the backup: the bookmark of the chosen folder could not be made. The person
/// chooses the folder again; no new attempt on the same folder helps, and no silent fallback exists.
public struct BackupFolderRegistrationFailure: Error, Equatable, Sendable {
    /// The one short sentence for this failure. The text of the system error means nothing to the person.
    public var message: String { BackupFolderRegistration.failureMessage }
}

/// The shared rule for adding a folder to the backup. The Mac app owns the security-scoped bookmark call itself and
/// passes it in, so this rule does not depend on a platform API.
public enum BackupFolderRegistration {
    /// "This folder could not be opened."
    public static var failureMessage: String { L10n.string("backup.folder_open_failed") }

    /// The message line after a folder was added. The sentence of an earlier failed add goes away, because the folder
    /// is in the list now. A message of a sync stays: it belongs to a run that is on screen.
    public static func messageAfterSuccessfulAdd(current: String?) -> String? {
        current == failureMessage ? nil : current
    }

    /// The bookmark of `url`, or the failure that shows `failureMessage`.
    public static func bookmark(
        for url: URL, makeBookmark: (URL) throws -> Data
    ) -> Result<Data, BackupFolderRegistrationFailure> {
        do {
            return .success(try makeBookmark(url))
        } catch {
            return .failure(BackupFolderRegistrationFailure())
        }
    }
}
