import Foundation

/// One folder that the person chose to keep backed up, as the app last resolved its security-scoped bookmark.
public struct WatchedFolder: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var bookmark: Data
    /// The path of the folder, or nil while its bookmark does not resolve, for example on a drive that is not mounted.
    public var path: String?
    /// True while the bookmark does not resolve cleanly: the app does not read the folder.
    public var needsRenewal: Bool

    public init(id: UUID = UUID(), bookmark: Data, path: String?, needsRenewal: Bool) {
        self.id = id
        self.bookmark = bookmark
        self.path = path
        self.needsRenewal = needsRenewal
    }

    /// The path in the folder list. "?" is no absolute path, so `WatchedFolderScope` treats the folder as one whose
    /// location is unknown: none of its rows count as outside or as deleted.
    public var displayPath: String { path ?? "?" }
}

/// What the app learned when it resolved one bookmark.
public enum WatchedFolderBookmarkResolution: Sendable, Equatable {
    /// The bookmark resolved to the folder at `path`. A stale bookmark needs a new one: the person adds the folder
    /// again.
    case resolved(path: String, isStale: Bool)
    /// The bookmark did not resolve, for example because its drive is not mounted.
    case unresolved
}

/// The registered watched folders and the rule that turns bookmark resolutions into them (#1583). The Mac app owns the
/// bookmark calls and passes their results in; this type decides the folder list and the scope.
public struct WatchedFolderRegistry: Sendable, Equatable {
    public private(set) var folders: [WatchedFolder]
    /// False while the saved folder list is missing or could not be read: then no folder is known.
    public private(set) var isKnown: Bool

    /// `savedBookmarks` is the saved folder list, nil when it is missing or damaged.
    public init(savedBookmarks: [Data]?, resolve: (Data) -> WatchedFolderBookmarkResolution) {
        isKnown = savedBookmarks != nil
        folders = (savedBookmarks ?? []).map { bookmark in
            switch resolve(bookmark) {
            case .resolved(let path, let isStale):
                WatchedFolder(bookmark: bookmark, path: path, needsRenewal: isStale)
            case .unresolved:
                WatchedFolder(bookmark: bookmark, path: nil, needsRenewal: true)
            }
        }
        sort()
    }

    /// The bookmarks to save.
    public var bookmarks: [Data] { folders.map(\.bookmark) }

    /// The folders that the app may read now.
    public var readableFolders: [WatchedFolder] { folders.filter { !$0.needsRenewal && $0.path != nil } }

    /// Applies a new resolution of one folder's bookmark. A bookmark that resolves cleanly again, for example after its
    /// drive was mounted, makes the folder readable with its current path. One that no longer resolves keeps the last
    /// path, so its rows stay where they are, and marks the folder. Returns true when the folder changed.
    @discardableResult
    public mutating func apply(_ resolution: WatchedFolderBookmarkResolution, to id: WatchedFolder.ID) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        let before = folders[index]
        switch resolution {
        case .resolved(let path, let isStale):
            folders[index].path = path
            folders[index].needsRenewal = isStale
        case .unresolved:
            folders[index].needsRenewal = true
        }
        guard folders[index] != before else { return false }
        sort()
        return true
    }

    /// Resolves every folder again and applies the results. Returns true when a folder changed.
    @discardableResult
    public mutating func refresh(resolve: (Data) -> WatchedFolderBookmarkResolution) -> Bool {
        var changed = false
        for folder in folders where apply(resolve(folder.bookmark), to: folder.id) { changed = true }
        return changed
    }

    /// Adds the folder at `path`. It replaces a registered folder with the same path, and a folder whose bookmark does
    /// not resolve but recorded the same path (`lastKnownPath`), so a folder that the person adds again leaves no "?"
    /// entry behind. The saved list is known from now on.
    public mutating func add(
        bookmark: Data, path: String, lastKnownPath: (Data) -> String?
    ) {
        folders.removeAll { folder in
            folder.path == path || (folder.path == nil && lastKnownPath(folder.bookmark) == path)
        }
        folders.append(WatchedFolder(bookmark: bookmark, path: path, needsRenewal: false))
        isKnown = true
        sort()
    }

    /// Removes one folder. The saved list is known from now on, also when it is empty.
    public mutating func remove(_ id: WatchedFolder.ID) {
        folders.removeAll { $0.id == id }
        isKnown = true
    }

    /// The scope of the backup, given the folders whose access the app holds now.
    public func scope(readable: [URL]) -> WatchedFolderScope {
        WatchedFolderScope(readable: readable, registered: isKnown ? folders.map(\.displayPath) : nil)
    }

    private mutating func sort() {
        folders.sort { $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending }
    }
}
