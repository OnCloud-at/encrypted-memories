import Foundation

/// One folder that the person chose to keep backed up, as the app last resolved its security-scoped bookmark.
public struct WatchedFolder: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var bookmark: Data
    /// The path of the folder, or nil while its bookmark does not resolve, for example on a drive that is not mounted.
    public var path: String?
    /// True while the bookmark does not resolve cleanly: the app does not read the folder.
    public var needsRenewal: Bool
    /// Paths that the folder had before, for example the path its bookmark recorded before its drive was mounted under
    /// another name ("Drive 1"). Its rows from then keep that path. While the folder is registered, none of them counts
    /// as outside and none is read; they leave the queue when the person removes the folder (#1583).
    public var formerPaths: [String]

    public init(
        id: UUID = UUID(), bookmark: Data, path: String?, needsRenewal: Bool, formerPaths: [String] = []
    ) {
        self.id = id
        self.bookmark = bookmark
        self.path = path
        self.needsRenewal = needsRenewal
        self.formerPaths = formerPaths
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
/// bookmark calls and passes their results in; this type decides the folder list and the scope. `lastKnownPath` gives
/// the path that a bookmark recorded, also while its drive is not mounted.
public struct WatchedFolderRegistry: Sendable, Equatable {
    public private(set) var folders: [WatchedFolder]
    /// False while the saved folder list is missing or could not be read: then no folder is known.
    public private(set) var isKnown: Bool

    /// `savedBookmarks` is the saved folder list, nil when it is missing or damaged.
    public init(
        savedBookmarks: [Data]?,
        resolve: (Data) -> WatchedFolderBookmarkResolution,
        lastKnownPath: (Data) -> String? = { _ in nil }
    ) {
        isKnown = savedBookmarks != nil
        folders = (savedBookmarks ?? []).map { bookmark in
            switch resolve(bookmark) {
            case .resolved(let path, let isStale):
                WatchedFolder(
                    bookmark: bookmark, path: path, needsRenewal: isStale,
                    formerPaths: [lastKnownPath(bookmark)].compactMap { $0 }.filter { $0 != path })
            case .unresolved:
                WatchedFolder(bookmark: bookmark, path: nil, needsRenewal: true)
            }
        }
        mergeFoldersWithTheSamePath()
        sort()
    }

    /// The bookmarks to save.
    public var bookmarks: [Data] { folders.map(\.bookmark) }

    /// The folders that the app may read now.
    public var readableFolders: [WatchedFolder] { folders.filter { !$0.needsRenewal && $0.path != nil } }

    /// Applies a new resolution of one folder's bookmark. A bookmark that resolves cleanly again, for example after its
    /// drive was mounted, makes the folder readable with its current path; a path that it had before stays registered.
    /// One that no longer resolves keeps the last path, so its rows stay where they are, and marks the folder. Two
    /// folders that resolve to the same path become one. Returns true when the folder list changed.
    @discardableResult
    public mutating func apply(
        _ resolution: WatchedFolderBookmarkResolution, to id: WatchedFolder.ID,
        lastKnownPath: (Data) -> String? = { _ in nil }
    ) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        let before = folders
        switch resolution {
        case .resolved(let path, let isStale):
            let earlier = [folders[index].path, lastKnownPath(folders[index].bookmark)].compactMap { $0 }
            folders[index].formerPaths = Self.unique(folders[index].formerPaths + earlier).filter { $0 != path }
            folders[index].path = path
            folders[index].needsRenewal = isStale
        case .unresolved:
            folders[index].needsRenewal = true
        }
        mergeFoldersWithTheSamePath()
        guard folders != before else { return false }
        sort()
        return true
    }

    /// Resolves every folder again and applies the results. Returns true when the folder list changed.
    @discardableResult
    public mutating func refresh(
        resolve: (Data) -> WatchedFolderBookmarkResolution, lastKnownPath: (Data) -> String? = { _ in nil }
    ) -> Bool {
        var changed = false
        for folder in folders where apply(resolve(folder.bookmark), to: folder.id, lastKnownPath: lastKnownPath) {
            changed = true
        }
        return changed
    }

    /// Adds the folder at `path`. It replaces a registered folder with the same path, and a folder whose bookmark does
    /// not resolve but recorded the same path (`lastKnownPath`), so a folder that the person adds again leaves no "?"
    /// entry behind. The replaced folders' earlier paths stay registered. The saved list is known from now on.
    public mutating func add(
        bookmark: Data, path: String, lastKnownPath: (Data) -> String?
    ) {
        let replaced = folders.filter { folder in
            folder.path == path || (folder.path == nil && lastKnownPath(folder.bookmark) == path)
        }
        folders.removeAll { folder in replaced.contains { $0.id == folder.id } }
        folders.append(
            WatchedFolder(
                bookmark: bookmark, path: path, needsRenewal: false,
                formerPaths: Self.unique(replaced.flatMap(\.formerPaths)).filter { $0 != path }))
        isKnown = true
        sort()
    }

    /// Removes one folder with its earlier paths. The saved list is known from now on, also when it is empty.
    public mutating func remove(_ id: WatchedFolder.ID) {
        folders.removeAll { $0.id == id }
        isKnown = true
    }

    /// The scope of the backup, given the folders whose access the app holds now. Every earlier path of a folder counts
    /// as a registered folder that the app cannot read.
    public func scope(readable: [URL]) -> WatchedFolderScope {
        WatchedFolderScope(
            readable: readable, registered: isKnown ? folders.flatMap { [$0.displayPath] + $0.formerPaths } : nil)
    }

    /// Keeps one folder per path: the one that the app may read, or else the first one. It takes the others' earlier
    /// paths.
    private mutating func mergeFoldersWithTheSamePath() {
        var merged: [WatchedFolder] = []
        for folder in folders {
            guard let path = folder.path, let index = merged.firstIndex(where: { $0.path == path }) else {
                merged.append(folder)
                continue
            }
            var kept = merged[index].needsRenewal && !folder.needsRenewal ? folder : merged[index]
            let other = kept.id == folder.id ? merged[index] : folder
            kept.formerPaths = Self.unique(kept.formerPaths + other.formerPaths).filter { $0 != path }
            merged[index] = kept
        }
        folders = merged
    }

    private static func unique(_ paths: [String]) -> [String] {
        paths.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private mutating func sort() {
        folders.sort { $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending }
    }
}
