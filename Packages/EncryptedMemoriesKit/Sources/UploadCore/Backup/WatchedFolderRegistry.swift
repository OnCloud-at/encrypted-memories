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
    /// another name ("Drive 1"), oldest first. Its rows from then keep that path. While the folder is registered, none of
    /// them counts as outside and none is read; they leave the queue when the person removes the folder (#1583). The app
    /// saves them with the folder list (`WatchedFolderRegistry.pathsToSave`) and keeps the newest
    /// `WatchedFolderRegistry.formerPathLimit`.
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
    /// The most earlier paths that one folder keeps; an older one leaves first.
    public static let formerPathLimit = 8

    public private(set) var folders: [WatchedFolder]
    /// False while the saved folder list, or the saved paths of its folders, is missing or could not be read: then no
    /// folder is known.
    public private(set) var isKnown: Bool

    /// `savedBookmarks` is the saved folder list, nil when it is missing or damaged. `savedPaths` is the saved value of
    /// `pathsToSave`: each saved path of a folder counts as an earlier one until its bookmark resolves to it again. A
    /// list that the app saved before it kept the paths has none, and a value of another type is damaged.
    public init(
        savedBookmarks: [Data]?,
        savedPaths: Any? = nil,
        resolve: (Data) -> WatchedFolderBookmarkResolution,
        lastKnownPath: (Data) -> String? = { _ in nil }
    ) {
        let saved: [String: [String]]? = savedPaths == nil ? [:] : savedPaths as? [String: [String]]
        isKnown = savedBookmarks != nil && saved != nil
        var resolvedIDs: Set<WatchedFolder.ID> = []
        folders = (savedBookmarks ?? []).map { bookmark in
            var folder = WatchedFolder(
                bookmark: bookmark, path: nil, needsRenewal: true,
                formerPaths: Self.formerPaths(saved?[Self.pathKey(of: bookmark)] ?? [], besides: nil))
            let resolution = resolve(bookmark)
            if case .resolved = resolution { resolvedIDs.insert(folder.id) }
            Self.update(&folder, with: resolution, lastKnownPath: lastKnownPath)
            return folder
        }
        mergeFolders(withTheSamePathAmong: resolvedIDs)
        sort()
    }

    /// The bookmarks to save.
    public var bookmarks: [Data] { folders.map(\.bookmark) }

    /// The paths to save beside the bookmarks: a property list that maps the Base64 text of a bookmark to every path of
    /// its folder, the current one last. After a relaunch the current path counts as an earlier one too, should the
    /// bookmark then resolve to another path, so the rows from now keep a registered path. A folder without a path has
    /// no entry.
    public var pathsToSave: [String: [String]] {
        folders.reduce(into: [:]) { saved, folder in
            let paths = folder.formerPaths + [folder.path].compactMap { $0 }
            if !paths.isEmpty { saved[Self.pathKey(of: folder.bookmark)] = paths }
        }
    }

    /// True when the paths of a known folder list differ from `savedPaths`, the value that the app loaded: the launch
    /// saves them, so a path that a bookmark resolved to at this launch counts as an earlier one at the next.
    public func pathsNeedSaving(comparedTo savedPaths: Any?) -> Bool {
        isKnown && pathsToSave != (savedPaths as? [String: [String]] ?? [:])
    }

    /// The folders that the app may read now.
    public var readableFolders: [WatchedFolder] { folders.filter { !$0.needsRenewal && $0.path != nil } }

    /// Applies a new resolution of one folder's bookmark. A bookmark that resolves cleanly again, for example after its
    /// drive was mounted, makes the folder readable with its current path; a path that it had before stays registered.
    /// One that no longer resolves keeps the last path, so its rows stay where they are, and marks the folder. Two
    /// folders never become one here: another folder can still hold the path from before its own drive moved, so only
    /// `refresh` joins folders. Returns true when the folder list changed.
    @discardableResult
    public mutating func apply(
        _ resolution: WatchedFolderBookmarkResolution, to id: WatchedFolder.ID,
        lastKnownPath: (Data) -> String? = { _ in nil }
    ) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        let before = folders
        Self.update(&folders[index], with: resolution, lastKnownPath: lastKnownPath)
        guard folders != before else { return false }
        sort()
        return true
    }

    /// Applies a new resolution of every folder, then joins the folders whose bookmarks resolved to the same path in
    /// this refresh. A folder whose `resolve` gives nil stays as it is, for example one that the person added while the
    /// bookmarks resolved. Returns true when the folder list changed.
    @discardableResult
    public mutating func refresh(
        resolve: (Data) -> WatchedFolderBookmarkResolution?, lastKnownPath: (Data) -> String? = { _ in nil }
    ) -> Bool {
        let before = folders
        var resolvedIDs: Set<WatchedFolder.ID> = []
        for index in folders.indices {
            guard let resolution = resolve(folders[index].bookmark) else { continue }
            if case .resolved = resolution { resolvedIDs.insert(folders[index].id) }
            Self.update(&folders[index], with: resolution, lastKnownPath: lastKnownPath)
        }
        mergeFolders(withTheSamePathAmong: resolvedIDs)
        guard folders != before else { return false }
        sort()
        return true
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
                formerPaths: Self.formerPaths(replaced.flatMap(\.formerPaths), besides: path)))
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

    private static func update(
        _ folder: inout WatchedFolder, with resolution: WatchedFolderBookmarkResolution,
        lastKnownPath: (Data) -> String?
    ) {
        switch resolution {
        case .resolved(let path, let isStale):
            // The path that the bookmark recorded is its oldest one; the path until now is the newest.
            let earlier = [lastKnownPath(folder.bookmark)].compactMap { $0 } + folder.formerPaths + [folder.path]
            folder.formerPaths = formerPaths(earlier.compactMap { $0 }, besides: path)
            folder.path = path
            folder.needsRenewal = isStale
        case .unresolved:
            folder.needsRenewal = true
        }
    }

    /// Keeps one folder per path among the folders in `ids`, whose bookmarks all resolved in one pass: the one that the
    /// app may read, or else the first one. It takes the others' earlier paths. A folder outside `ids` keeps its entry,
    /// also with the path of another folder: that path may be the one it had before its own drive moved.
    private mutating func mergeFolders(withTheSamePathAmong ids: Set<WatchedFolder.ID>) {
        var merged: [WatchedFolder] = []
        for folder in folders {
            guard ids.contains(folder.id), let path = folder.path,
                let index = merged.firstIndex(where: { ids.contains($0.id) && $0.path == path })
            else {
                merged.append(folder)
                continue
            }
            var kept = merged[index].needsRenewal && !folder.needsRenewal ? folder : merged[index]
            let other = kept.id == folder.id ? merged[index] : folder
            kept.formerPaths = Self.formerPaths(kept.formerPaths + other.formerPaths, besides: path)
            merged[index] = kept
        }
        folders = merged
    }

    /// `paths` once each, oldest first, without the current path and with at most `formerPathLimit` of the newest. A path
    /// that comes again counts at its newest place.
    private static func formerPaths(_ paths: [String], besides current: String?) -> [String] {
        var seen = Set([current].compactMap { $0 })
        let newestFirst = paths.reversed().filter { seen.insert($0).inserted }
        return Array(newestFirst.prefix(formerPathLimit).reversed())
    }

    private static func pathKey(of bookmark: Data) -> String { bookmark.base64EncodedString() }

    private mutating func sort() {
        folders.sort { $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending }
    }
}
