import Observation
import PhotosCore
import TimelineCore
import UploadCore

/// Connects one account's `PendingGridSession` to the app, shared by iOS, iPadOS and macOS. It keeps the session
/// and its store for the teardown, shows the session's trash and excluded lists, counts changes of the favorite
/// intents, and hands album adds of pending photos to the session. The account host keeps the teardown order.
@MainActor
@Observable
public final class PendingGridConnection {
    /// Local photos on their way to Proton, merged into the whole-library grid. Nil while no session runs.
    public private(set) var session: PendingGridSession?
    /// Local photos in "Zuletzt gelöscht", shown with the Proton trash.
    public private(set) var trash = PendingTrashPresentation.empty
    /// Photos deleted before upload, for the Backup settings list.
    public private(set) var excludedTiles: [PendingTile] = []
    /// Changes when pending favorite intents change, so favorite displays refresh.
    public private(set) var favoriteRevision: UInt64 = 0
    @ObservationIgnored private var store: PendingBackupManifestStore?
    @ObservationIgnored private var lastFavoriteIntents: [PhotoUID: Bool] = [:]

    public init() {}

    /// Keeps `store` for the teardown, also when no session can start, and starts the session that `makeSession`
    /// builds over it. `prepare` attaches the host's presentation before the session starts. `albumAdds` installs
    /// the album-add handler in the account's albums; without it, album adds of pending photos do not reach the
    /// session. Returns nil without a store or when the session cannot start.
    @discardableResult
    public func start(
        store: PendingBackupManifestStore?,
        makeSession: (PendingBackupManifestStore) -> PendingGridSession?,
        albumAdds: (@Sendable (@escaping @Sendable ([PhotoUID], String) async -> Bool) async -> Void)? = nil,
        prepare: (PendingGridSession) -> Void = { _ in }
    ) -> PendingGridSession? {
        self.store = store
        guard let store, let session = makeSession(store) else { return nil }
        session.onListsChange = { [weak self, weak session] in
            guard let self, let session else { return }
            trash = session.trash
            excludedTiles = session.excludedTiles
        }
        session.onPendingChange = { [weak self] snapshot in
            guard let self, snapshot.favoriteIntents != lastFavoriteIntents else { return }
            lastFavoriteIntents = snapshot.favoriteIntents
            favoriteRevision &+= 1
        }
        if let albumAdds {
            Task { [weak session] in
                await albumAdds { [weak session] uids, albumID in
                    await session?.addToAlbum(uids, albumID: albumID) ?? false
                }
            }
        }
        self.session = session
        prepare(session)
        session.start()
        return session
    }

    /// Detaches the session and its store and empties the lists. The caller closes the session before the backup
    /// controller shuts down, and the store after it.
    public func retire() -> (session: PendingGridSession?, store: PendingBackupManifestStore?) {
        let retired = (session, store)
        session = nil
        store = nil
        trash = .empty
        excludedTiles = []
        lastFavoriteIntents = [:]
        favoriteRevision &+= 1
        return retired
    }
}
