import Foundation

/// The Drive SDK's encrypted, account-scoped on-disk SQLite cache.
public enum SDKMetadataStore {
    public static func encryptedCacheFileNames(uid: String) -> [String] {
        sqliteFamily(base: "sdk-cache-v1-\(uid).sqlite")
    }

    /// File names of the current encrypted SDK cache for `uid`, including SQLite sidecars.
    public static func metadataFileNames(uid: String) -> [String] {
        encryptedCacheFileNames(uid: uid)
    }

    /// Best-effort delete of every metadata file for `uid` under `directory`. Returns the number of
    /// files actually removed (i.e. that existed), so a caller or test can confirm the purge ran.
    /// Files belonging to other accounts are left untouched.
    @discardableResult
    public static func purgeMetadata(in directory: URL, uid: String) -> Int {
        remove(metadataFileNames(uid: uid), in: directory)
    }

    private static func sqliteFamily(base: String) -> [String] {
        [base, base + "-wal", base + "-shm"]
    }

    private static func remove(_ names: [String], in directory: URL) -> Int {
        let fm = FileManager.default
        var removed = 0
        for name in names {
            if (try? fm.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}
