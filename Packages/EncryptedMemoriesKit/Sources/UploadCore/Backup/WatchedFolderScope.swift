import Foundation

/// The watched folders as a returned file sees them: the folders the app can read now, and every
/// folder the person registered, readable or not.
public struct WatchedFolderScope: Sendable, Equatable {
    /// Where one returned watched file lies.
    public enum Location: Sendable, Equatable {
        /// The file lies in a watched folder that the app can read now.
        case readable(URL)
        /// No registered folder holds the file: the folder it came from is no longer watched.
        case outside
        /// The file may lie in a registered folder that the app cannot read now, for example a
        /// folder that needs a new bookmark, or every folder after the folder backup shut down.
        case unavailable
    }

    /// Root paths of the folders the app can read now, each with a trailing slash.
    let readableRoots: [String]
    /// Root paths of every registered folder, each with a trailing slash. Nil when a registered
    /// folder has no known path or the registry is not loaded, so no path is proven outside.
    let registeredRoots: [String]?

    /// No folder is readable and no folder is known.
    public static let unavailable = WatchedFolderScope(readableRoots: [], registeredRoots: nil)

    /// `registered` holds the path of every registered folder, or nil when the registry could not
    /// be read. A path that is not absolute marks a folder whose location is unknown.
    public init(readable: [URL], registered: [String]?) {
        var registeredRoots: [String]?
        if let registered, registered.allSatisfy({ $0.hasPrefix("/") }) {
            registeredRoots = registered.map(Self.root)
        }
        self.init(readableRoots: readable.map { Self.root($0.path) }, registeredRoots: registeredRoots)
    }

    /// The registered folder bookmarks in a stored value. Only a saved list is known; the app saves an empty list
    /// when the person removes the last folder. No stored value, for example after the settings were reset, and a
    /// value of another type give nil, so no registered folder is known (#1583).
    public static func registeredBookmarks(storedValue: Any?) -> [Data]? {
        storedValue as? [Data]
    }

    private init(readableRoots: [String], registeredRoots: [String]?) {
        self.readableRoots = readableRoots
        self.registeredRoots = registeredRoots
    }

    /// The folder that the app can read now and that holds the path.
    func readableRoot(forPath path: String) -> URL? {
        readableRoots.first { path.hasPrefix($0) }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The file behind a path, when it lies in a folder the app can read now.
    public func readableURL(forPath path: String) -> URL? {
        readableRoot(forPath: path).map { _ in URL(fileURLWithPath: path) }
    }

    /// Only a path outside every known registered folder counts as outside.
    public func location(ofPath path: String) -> Location {
        if let url = readableURL(forPath: path) { return .readable(url) }
        guard let registeredRoots else { return .unavailable }
        return registeredRoots.contains(where: { path.hasPrefix($0) }) ? .unavailable : .outside
    }

    /// The folder files that a backup pass may claim now (#1583). `rootExists` tells whether a readable folder is still
    /// there; a drive that went away leaves its folder readable in the scope until the next folder scan.
    public func claimFilter(
        rootExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> BackupFileClaimFilter {
        BackupFileClaimFilter(
            presentRoots: readableRoots.filter(rootExists), readableRoots: readableRoots,
            registeredRoots: registeredRoots)
    }

    private static func root(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasSuffix("/") ? standardized : standardized + "/"
    }
}

/// The folder files that a backup pass may claim: a file in a readable folder that is still there, and a file that no
/// registered folder holds. Every other folder file may lie in a folder that the app cannot reach now, for example on a
/// drive that is not mounted: it stays unclaimed and unchanged until its folder is back (#1583). The rule mirrors the
/// one of `FileBackupResourceResolver`, which refuses the same files. Other source kinds are not affected.
public struct BackupFileClaimFilter: Sendable, Equatable {
    /// Readable roots that exist now, each with a trailing slash.
    let presentRoots: [String]
    /// Every readable root, also one whose folder went away.
    let readableRoots: [String]
    /// Nil when no path is proven outside the registered folders.
    let registeredRoots: [String]?

    /// True when a backup pass may claim the folder file at `path`.
    public func admits(path: String) -> Bool {
        if presentRoots.contains(where: { path.hasPrefix($0) }) { return true }
        guard let registeredRoots, !readableRoots.contains(where: { path.hasPrefix($0) }) else { return false }
        return !registeredRoots.contains(where: { path.hasPrefix($0) })
    }
}
