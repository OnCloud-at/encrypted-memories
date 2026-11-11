import Foundation

/// The file writes under a durable file: an atomic replacement and appends to an open file. Production writes to the
/// local disk (`LocalDurableFileSystem`). A journal keeps its records through this seam, so every write it makes can
/// be replaced, for example to make one of them fail.
public protocol DurableFileSystem: Sendable {
    /// Replaces the file at `url` with `data` in one atomic step: a process that ends during the replacement leaves
    /// either the earlier bytes or `data`. No sync to disk is made, so a power loss can still lose a recent write.
    func replace(_ url: URL, with data: Data) throws
    /// Opens the existing file at `url` for writes at its end.
    func openForAppending(_ url: URL) throws -> any DurableFileAppending
}

/// An open file that a durable writer appends to.
public protocol DurableFileAppending: AnyObject {
    /// Moves to the end of the file and returns its length.
    func seekToEnd() throws -> UInt64
    /// Writes `data` at the current position. A failure can leave a part of `data` in the file.
    func write(_ data: Data) throws
    /// Cuts the file back to `offset` bytes.
    func truncate(atOffset offset: UInt64) throws
    func close() throws
}

/// The local disk: `Data.write(to:options: .atomic)` for a replacement and a `FileHandle` for appends.
public struct LocalDurableFileSystem: DurableFileSystem {
    public init() {}

    public func replace(_ url: URL, with data: Data) throws {
        try data.write(to: url, options: .atomic)
    }

    public func openForAppending(_ url: URL) throws -> any DurableFileAppending {
        LocalFileAppender(handle: try FileHandle(forWritingTo: url))
    }
}

private final class LocalFileAppender: DurableFileAppending {
    let handle: FileHandle

    init(handle: FileHandle) { self.handle = handle }

    func seekToEnd() throws -> UInt64 { try handle.seekToEnd() }
    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    func truncate(atOffset offset: UInt64) throws { try handle.truncate(atOffset: offset) }
    func close() throws { try handle.close() }
}

/// An appended file that cuts a failed append back off: when the write of an append fails, it cuts the file back to its
/// length before that append, so the next append starts on a clean end. When that cut fails too, the file may end in a
/// part of a record, and the writer accepts no further append. `replace(with:)` writes the whole file anew.
public struct DurableFileWriter {
    /// The writer accepts no append after a failed append whose bytes it could not remove.
    public struct Unusable: Error {}

    private let url: URL
    private let fileSystem: any DurableFileSystem
    /// Set when a failed append could not be cut back.
    public private(set) var writeFailed = false

    public init(url: URL, fileSystem: any DurableFileSystem = LocalDurableFileSystem()) {
        self.url = url
        self.fileSystem = fileSystem
    }

    /// Adds `data` at the end of the file. A missing file is created with `data` in one atomic step. Returns true
    /// when it created the file. Throws `Unusable` after a failed append that could not be cut back.
    public mutating func append(_ data: Data) throws -> Bool {
        guard !writeFailed else { throw Unusable() }
        if !FileManager.default.fileExists(atPath: url.path) {
            try fileSystem.replace(url, with: data)
            return true
        }
        let file = try fileSystem.openForAppending(url)
        defer { try? file.close() }
        let end = try file.seekToEnd()
        do {
            try file.write(data)
        } catch {
            // A part of `data` may be in the file, for example when the disk filled up. The next append would join
            // it, so the file goes back to its length before this append.
            do {
                try file.truncate(atOffset: end)
            } catch {
                writeFailed = true
            }
            throw error
        }
        return false
    }

    /// Replaces the whole file with `data` in one atomic step.
    public func replace(with data: Data) throws {
        try fileSystem.replace(url, with: data)
    }
}
