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
    /// True while the last resolution of the bookmark failed, for example because its drive is not mounted; false while
    /// it resolved, also to a stale bookmark.
    public var isDisconnected: Bool
    /// The path that the bookmark recorded, also while its drive is not mounted.
    public var recordedPath: String?

    public init(
        id: UUID = UUID(), bookmark: Data, path: String?, needsRenewal: Bool, formerPaths: [String] = [],
        isDisconnected: Bool = false, recordedPath: String? = nil
    ) {
        self.id = id
        self.bookmark = bookmark
        self.path = path
        self.needsRenewal = needsRenewal
        self.formerPaths = formerPaths
        self.isDisconnected = isDisconnected
        self.recordedPath = recordedPath
    }

    /// The path of the folder for the scope. "?" is no absolute path, so `WatchedFolderScope` treats the folder as one
    /// whose location is unknown: none of its rows count as outside or as deleted.
    public var displayPath: String { path ?? "?" }

    /// The path that the folder list shows: the current path, or else the last path that the app knows for the folder
    /// (the newest saved path, then the path that the bookmark recorded), or else "?".
    public var shownPath: String { path ?? formerPaths.last ?? recordedPath ?? "?" }

    /// The line that the folder list shows under the folder, nil while the app reads the folder.
    public var notice: WatchedFolderNotice? {
        guard needsRenewal else { return nil }
        return isDisconnected ? .driveNotConnected : .mustBeAddedAgain
    }
}

/// Why the app does not read a registered folder, as the folder list tells the person.
public enum WatchedFolderNotice: Sendable, Equatable {
    /// The bookmark did not resolve, for example because the drive is not connected. The folder is read again once the
    /// bookmark resolves.
    case driveNotConnected
    /// The bookmark resolved, but the app may not read the folder with it: the person adds the folder again.
    case mustBeAddedAgain
}

/// What the app learned when it resolved one bookmark.
public enum WatchedFolderBookmarkResolution: Sendable, Equatable {
    /// The bookmark resolved to the folder at `path`. A stale bookmark needs a new one: the person adds the folder
    /// again.
    case resolved(path: String, isStale: Bool)
    /// The bookmark did not resolve, for example because its drive is not mounted.
    case unresolved

    /// The scan of a pass could not use the bookmark: `resolvedPath` is the path that it resolved to, nil when it did
    /// not resolve. A bookmark that resolved but was stale, or whose folder the app may not open, needs a new one.
    public static func afterFailedAccess(resolvedPath: String?) -> Self {
        resolvedPath.map { .resolved(path: $0, isStale: true) } ?? .unresolved
    }

    /// The scan could not read the folder at `rootPath` itself: a missing folder is one whose drive went away, and a
    /// folder that the app may not read needs a new bookmark.
    public static func afterRootReadFailure(_ failure: FolderEnumerationError.FailureClass, rootPath: String) -> Self {
        failure == .missing ? .unresolved : .resolved(path: rootPath, isStale: true)
    }
}

/// The registered watched folders and the rule that turns bookmark resolutions into them (#1583). The Mac app owns the
/// bookmark calls and passes their results in; this type decides the folder list and the scope. `lastKnownPath` gives
/// the path that a bookmark recorded, also while its drive is not mounted.
public struct WatchedFolderRegistry: Sendable, Equatable {
    /// The most earlier paths that one folder keeps besides the path that its bookmark recorded, which it always keeps;
    /// an older one leaves first.
    public static let formerPathLimit = 8

    public private(set) var folders: [WatchedFolder]
    /// False while the saved folder list is missing or could not be read.
    private var listIsKnown: Bool
    /// True from a launch that found the saved paths damaged until the app saved them again.
    private var savedPathsAreDamaged: Bool
    /// False while the saved folder list is missing or could not be read, and while the saved paths of its folders could
    /// not be read and were not saved again (`pathsWereSaved()`): then no folder is known. Adding or removing a folder
    /// makes the list known, but not its lost paths.
    public var isKnown: Bool { listIsKnown && !savedPathsAreDamaged }

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
        listIsKnown = savedBookmarks != nil
        savedPathsAreDamaged = saved == nil
        var resolvedIDs: Set<WatchedFolder.ID> = []
        folders = (savedBookmarks ?? []).map { bookmark in
            // The last saved path is the one the folder had then; it is no earlier path yet, so it takes no place of the
            // limit until the bookmark resolves elsewhere.
            let paths = saved?[Self.pathKey(of: bookmark)] ?? []
            var folder = WatchedFolder(
                bookmark: bookmark, path: nil, needsRenewal: true,
                formerPaths: Self.formerPaths(
                    paths, besides: nil, keeping: [lastKnownPath(bookmark), paths.last].compactMap { $0 }))
            let resolution = resolve(bookmark)
            if case .resolved = resolution { resolvedIDs.insert(folder.id) }
            Self.update(&folder, with: resolution, lastKnownPath: lastKnownPath)
            return folder
        }
        mergeFolders(withTheSamePathAmong: resolvedIDs, lastKnownPath: lastKnownPath)
        sort()
    }

    /// The app saved `bookmarks` and `pathsToSave`: saved paths that were damaged at launch are replaced, so the list is
    /// known again once it is known otherwise.
    public mutating func pathsWereSaved() {
        savedPathsAreDamaged = false
    }

    /// True when the saved values of this list differ from those of `before`: its bookmarks or its paths. The app saves
    /// the list after each change for which this holds.
    public func needsSaving(since before: WatchedFolderRegistry) -> Bool {
        bookmarks != before.bookmarks || pathsToSave != before.pathsToSave
    }

    /// The changes of the folder access that the app holds, given the path of each held access: it stops each access
    /// whose folder is no longer readable or now has another path, and starts one for each readable folder without an
    /// access, also for a folder whose access it stops now. So the readable scope always lists the readable folders at
    /// their current paths, also after a drive came back under another name.
    public func accessChanges(
        holding held: [WatchedFolder.ID: String]
    ) -> (stop: Set<WatchedFolder.ID>, start: [WatchedFolder]) {
        let readable = Dictionary(
            uniqueKeysWithValues: readableFolders.compactMap { folder in folder.path.map { (folder.id, $0) } })
        let stop = Set(held.filter { readable[$0.key] != $0.value }.keys)
        let start = readableFolders.filter { held[$0.id] == nil || stop.contains($0.id) }
        return (stop, start)
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
        mergeFolders(withTheSamePathAmong: resolvedIDs, lastKnownPath: lastKnownPath)
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
                formerPaths: Self.formerPaths(
                    replaced.flatMap(\.formerPaths), besides: path,
                    keeping: replaced.compactMap { lastKnownPath($0.bookmark) }),
                recordedPath: lastKnownPath(bookmark)))
        listIsKnown = true
        sort()
    }

    /// Removes one folder with its earlier paths. The saved list is known from now on, also when it is empty.
    public mutating func remove(_ id: WatchedFolder.ID) {
        folders.removeAll { $0.id == id }
        listIsKnown = true
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
        let recordedPath = lastKnownPath(folder.bookmark)
        if let recordedPath { folder.recordedPath = recordedPath }
        switch resolution {
        case .resolved(let path, let isStale):
            folder.isDisconnected = false
            // The path that the bookmark recorded is its oldest one; the path until now is the newest.
            let recorded = [recordedPath].compactMap { $0 }
            let earlier = recorded + folder.formerPaths + [folder.path].compactMap { $0 }
            folder.formerPaths = formerPaths(earlier, besides: path, keeping: recorded)
            folder.path = path
            folder.needsRenewal = isStale
        case .unresolved:
            folder.needsRenewal = true
            folder.isDisconnected = true
        }
    }

    /// Keeps one folder per path among the folders in `ids`, whose bookmarks all resolved in one pass: the one that the
    /// app may read, or else the first one. It takes the others' earlier paths. A folder outside `ids` keeps its entry,
    /// also with the path of another folder: that path may be the one it had before its own drive moved.
    private mutating func mergeFolders(
        withTheSamePathAmong ids: Set<WatchedFolder.ID>, lastKnownPath: (Data) -> String?
    ) {
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
            kept.formerPaths = Self.formerPaths(
                kept.formerPaths + other.formerPaths, besides: path,
                keeping: [kept, other].compactMap { lastKnownPath($0.bookmark) })
            merged[index] = kept
        }
        folders = merged
    }

    /// `paths` once each, oldest first, without the current path: every path in `recorded` (the paths that bookmarks
    /// recorded, where most rows of a folder usually lie) and at most `formerPathLimit` of the newest others. A path that
    /// comes again counts at its newest place.
    private static func formerPaths(
        _ paths: [String], besides current: String?, keeping recorded: [String]
    ) -> [String] {
        var seen = Set([current].compactMap { $0 })
        var others = 0
        let newestFirst = paths.reversed().filter { seen.insert($0).inserted }.filter { path in
            if recorded.contains(path) { return true }
            others += 1
            return others <= formerPathLimit
        }
        return Array(newestFirst.reversed())
    }

    private static func pathKey(of bookmark: Data) -> String { bookmark.base64EncodedString() }

    private mutating func sort() {
        folders.sort { $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending }
    }
}
