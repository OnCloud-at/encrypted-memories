import Foundation
import UploadCore

/// What a native backup problem sheet lists: the photo backup, or the last run of one synced album. The macOS and iOS
/// sheets share this state, so both read the same rows and follow the same changes; only the layout is native.
@MainActor
public enum BackupProblemSheetSource {
    case backup(PhotoLibraryBackupController)
    case album(AlbumSyncController, albumID: String)

    /// Names the controller, and the album, that a session reads.
    /// A session made for another ID lists no rows and shows the loading state.
    public var id: String {
        switch self {
        case .backup(let controller): "backup-\(ObjectIdentifier(controller))"
        case .album(let controller, let albumID): "album-\(ObjectIdentifier(controller))-\(albumID)"
        }
    }

    public var backupController: PhotoLibraryBackupController? {
        if case .backup(let controller) = self { controller } else { nil }
    }

    /// False for an album that left the selection: its sheet lists nothing.
    var isSelected: Bool {
        if case .album(let controller, let albumID) = self {
            return controller.selectedAlbumIDs.contains(albumID)
        }
        return true
    }

    /// Whether the summary counts photos that need attention, so an empty list is no answer yet.
    var expectsItems: Bool {
        switch self {
        case .backup(let controller): controller.status.needsAttentionCount > 0
        case .album(let controller, let albumID):
            controller.selectedAlbums.first { $0.id == albumID }?.hasNeedsAttention == true
        }
    }

    public func makeSession() -> BackupProblemListSession {
        switch self {
        case .backup(let controller): controller.makeProblemListSession()
        case .album(let controller, let albumID): controller.makeProblemListSession(albumID: albumID)
        }
    }

    /// Whether a session made for `sessionSourceID` belongs to this source.
    public func owns(_ sessionSourceID: String) -> Bool {
        sessionSourceID == id
    }

    /// The rows of `session`, which the sheet made for `sessionSourceID`. Empty when that is not this source or
    /// when the album is not selected.
    public func items(of session: BackupProblemListSession, madeFor sessionSourceID: String) -> [BackupFailedItem] {
        guard selectionPresentation(madeFor: sessionSourceID) == nil else { return [] }
        return session.rows.map(\.item)
    }

    public func presentation(
        of session: BackupProblemListSession, madeFor sessionSourceID: String
    ) -> BackupProblemListPresentation {
        if let presentation = selectionPresentation(madeFor: sessionSourceID) { return presentation }
        return session.presentation(expectsItems: expectsItems)
    }

    /// Nil for this selected source; otherwise the state that hides its session.
    private func selectionPresentation(madeFor sessionSourceID: String) -> BackupProblemListPresentation? {
        guard owns(sessionSourceID) else { return .loading }
        guard isSelected else { return .empty }
        return nil
    }

    /// True when the sheet must replace `session`: it was made for another source, or it was retired.
    public func needsNewSession(_ session: BackupProblemListSession, madeFor sessionSourceID: String) -> Bool {
        !owns(sessionSourceID) || session.isRetired
    }

    /// Changes when the sheet must follow its list again: a new session, another source, or a new problem list of the
    /// backup or of the album.
    public struct FollowKey: Equatable {
        let session: ObjectIdentifier
        let source: String
        let backup: BackupStatus.ProblemListKey?
        let album: UUID?
    }

    public func followKey(for session: BackupProblemListSession) -> FollowKey {
        let albumRevision: UUID?
        if case .album(let controller, _) = self {
            albumRevision = controller.problemListRevision
        } else {
            albumRevision = nil
        }
        return FollowKey(
            session: ObjectIdentifier(session), source: id, backup: backupController?.status.problemListKey,
            album: albumRevision)
    }

    /// Follows only this selected source's session. The backup keeps following its changes until the task ends.
    public func follow(_ session: BackupProblemListSession, madeFor sessionSourceID: String) async {
        guard selectionPresentation(madeFor: sessionSourceID) == nil else { return }
        switch self {
        case .backup(let controller): await controller.followProblemList(session: session)
        case .album:
            session.requestRefresh()
            await session.waitUntilIdle()
        }
    }
}
