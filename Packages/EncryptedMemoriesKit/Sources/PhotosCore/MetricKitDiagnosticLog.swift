import Foundation

/// The MetricKit section of the support report: the kept summaries, oldest first, and the number of older ones that the
/// bounds dropped.
public struct MetricKitDiagnosticSupportSnapshot: Codable, Sendable, Equatable {
    public let entries: [[String: String]]
    public let dropped: Int

    public init(entries: [[String: String]] = [], dropped: Int = 0) {
        self.entries = entries
        self.dropped = dropped
    }
}

/// The last MetricKit diagnostics of this device as summaries, kept in one small file. MetricKit delivers a crash with
/// the next launch, and the support file is made later, so the summaries must outlive the process.
///
/// The file holds at most `entryLimit` summaries and at most `byteLimit` bytes of them; the oldest summaries go first,
/// and `dropped` counts them. A summary holds only fields of the `MetricKitDiagnostic` support allowlist, and the
/// export filters every stored entry through that allowlist again, so a file with a foreign key cannot leak it.
///
/// The file has no file protection, as the background-window ledger: a MetricKit delivery can come with a launch before
/// the first unlock. It holds no account data, and it lies in the local data that sign-out removes. A file that cannot
/// be read is not overwritten; a damaged file is replaced.
///
/// While a sign-out purge is pending, nothing is written, and the summary of a diagnostic that arrives then is lost;
/// whether MetricKit delivers it again is not verified. The check is not atomic with the write: a purge requested
/// between the check and the write removes the directory, and the write can bring the file back with one summary. The
/// background-window ledger closes this window with a purge generation that its own lock guards. This log does not copy
/// that piece: a summary holds no account data, so the file that returns carries nothing of the signed-out account.
public final class MetricKitDiagnosticLog: @unchecked Sendable {
    public static let entryLimit = 20
    public static let byteLimit = 24_576
    public static let defaultFileURL: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("EncryptedMemories/metrickit-diagnostics-v1.json", isDirectory: false)
    /// The app's file. A process that is no app, such as the package test runner, keeps no file.
    public static let shared = MetricKitDiagnosticLog(
        fileURL: Bundle.main.bundleURL.pathExtension == "app" ? defaultFileURL : nil)
    static let fileWriteOptions: Data.WritingOptions = [.atomic, .noFileProtection]

    private struct File: Codable {
        var entries: [[String: String]]
        var dropped: Int
    }

    /// One lock for every file, as the read-change-write of two logs on one file must not interleave.
    private static let lock = NSLock()
    private let fileURL: URL?
    private let entryLimit: Int
    private let byteLimit: Int
    private let isPurgePending: @Sendable () -> Bool

    public init(
        fileURL: URL?, entryLimit: Int = MetricKitDiagnosticLog.entryLimit,
        byteLimit: Int = MetricKitDiagnosticLog.byteLimit,
        isPurgePending: @escaping @Sendable () -> Bool = { BackupLocalDataPurge.isPurgePending() }
    ) {
        self.fileURL = fileURL
        self.entryLimit = entryLimit
        self.byteLimit = byteLimit
        self.isPurgePending = isPurgePending
    }

    /// Keeps the summary of one diagnostic. The same summary a second time is not kept.
    public func record(_ input: MetricKitDiagnosticInput) {
        guard let fileURL, !isPurgePending() else { return }
        let fields = MetricKitDiagnosticSummary.fields(for: input)
        Self.lock.withLock {
            guard var file = load(fileURL), !file.entries.contains(fields) else { return }
            file.entries.append(fields)
            while !file.entries.isEmpty && (file.entries.count > entryLimit || encodedSize(file.entries) > byteLimit) {
                file.entries.removeFirst()
                file.dropped += 1
            }
            write(file, to: fileURL)
        }
    }

    public func supportSnapshot() -> MetricKitDiagnosticSupportSnapshot {
        guard let fileURL, let file = Self.lock.withLock({ load(fileURL) }) else {
            return MetricKitDiagnosticSupportSnapshot()
        }
        let entries = file.entries.compactMap { entry -> [String: String]? in
            let allowed = PhotoDiagnostics.sanitizedSupportFields(event: "MetricKitDiagnostic", fields: entry) ?? [:]
            return allowed.isEmpty ? nil : allowed
        }
        return MetricKitDiagnosticSupportSnapshot(entries: entries, dropped: file.dropped)
    }

    /// The stored file; empty for a missing or a damaged file. Nil when the file cannot be read: its content is not
    /// known, so nothing may overwrite it.
    private func load(_ fileURL: URL) -> File? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return File(entries: [], dropped: 0)
        } catch {
            return nil
        }
        return (try? JSONDecoder().decode(File.self, from: data)) ?? File(entries: [], dropped: 0)
    }

    private func encodedSize(_ entries: [[String: String]]) -> Int {
        (try? JSONEncoder().encode(entries).count) ?? Int.max
    }

    private func write(_ file: File, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: Self.fileWriteOptions)
        } catch {
            // A diagnostic that cannot be kept is lost; it never changes the app.
        }
    }
}
