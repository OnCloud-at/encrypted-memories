import Foundation

/// Lightweight file logger for local debugging. Disabled by default because the messages can contain local
/// filenames, node IDs, or API paths. Enable only for a deliberate Debug run with
/// `ENCRYPTED_MEMORIES_DEBUG_LOG=1`; Release never writes this log.
public enum DebugLog {
    private static let queue = DispatchQueue(label: "encryptedmemories.debuglog")
    private static let url: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("EncryptedMemories", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("encryptedmemories.log")
    }()

    /// Whether the log is active (Debug build + `ENCRYPTED_MEMORIES_DEBUG_LOG=1`). Callers can gate extra
    /// diagnostic work (e.g. the post-trash listing verification) on this so Release pays nothing.
    public static var isEnabled: Bool { enabled }

    public static func log(_ message: String) {
        guard enabled else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }

    /// Waits until every already-enqueued write has completed. Account teardown calls this before
    /// deleting the log root so a late debug write cannot recreate it after the purge succeeds.
    public static func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private static var enabled: Bool {
        #if DEBUG
            return ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_DEBUG_LOG"] == "1"
        #else
            return false
        #endif
    }
}
