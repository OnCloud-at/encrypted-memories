import Foundation
import PhotosCore

/// Cosmetic replacement facts for one process. These facts never control backup or trash operations.
public final class PendingReplacementLedger: @unchecked Sendable {
    private struct Key: Hashable {
        let source: PendingSourceKey
        let revision: UploadBackupRevision
    }

    private struct Entry {
        var replaces: [PhotoUID]
        var remote: PhotoUID?
        var settled: Bool = false
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: PendingReplacementLedger] = [:]
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    /// The attempt of a source that left the grid. Its late callbacks must not record it again; another
    /// revision (a newer edit, or an undo to an earlier one) and a new attempt after `readmit` record normally.
    private var blocked: [PendingSourceKey: UploadBackupRevision] = [:]

    public init() {}

    /// Strong ownership keeps records across controller and recorder rebuilds in the same process.
    public static func shared(accountDataDirectory: URL) -> PendingReplacementLedger {
        let key = accountDataDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return registryLock.withLock {
            if let ledger = registry[key] { return ledger }
            let ledger = PendingReplacementLedger()
            registry[key] = ledger
            return ledger
        }
    }

    /// Called after account owners stop during explicit sign-out, before the account directories are purged.
    public static func clearForSignOut(accountDataDirectory: URL? = nil) {
        registryLock.withLock {
            if let accountDataDirectory {
                let key = accountDataDirectory.standardizedFileURL.resolvingSymlinksInPath().path
                if let ledger = registry.removeValue(forKey: key) {
                    ledger.lock.withLock {
                        ledger.entries.removeAll()
                        ledger.blocked.removeAll()
                    }
                }
            } else {
                for ledger in registry.values {
                    ledger.lock.withLock {
                        ledger.entries.removeAll()
                        ledger.blocked.removeAll()
                    }
                }
                registry.removeAll()
            }
        }
    }

    func record(_ key: PendingSourceKey, revision: UploadBackupRevision, replaces: [PhotoUID]) {
        guard !replaces.isEmpty else { return }
        lock.withLock {
            guard blocked[key] != revision else { return }
            let key = Key(source: key, revision: revision)
            if entries[key] == nil { entries[key] = Entry(replaces: replaces) }
        }
    }

    func recordHandoff(_ handoff: PendingHandoff, seed: () -> [PhotoUID]) {
        guard handoff.kind == .uploaded, handoff.key.kind == .photoLibraryAsset else { return }
        lock.withLock {
            guard blocked[handoff.key] != handoff.revision else { return }
            let key = Key(source: handoff.key, revision: handoff.revision)
            if entries[key] == nil {
                let replaces = seed()
                guard !replaces.isEmpty else { return }
                entries[key] = Entry(replaces: replaces)
            }
            entries[key]?.remote = handoff.remote
        }
    }

    /// Narrow only the mains recorded for this revision. Historical and related links cannot join it.
    func settle(_ key: PendingSourceKey, revision: UploadBackupRevision, retired: Set<String>) -> [PhotoUID]? {
        lock.withLock {
            guard blocked[key] != revision else { return nil }
            let key = Key(source: key, revision: revision)
            guard var entry = entries[key], !entry.replaces.isEmpty else { return nil }
            let replaces = entry.replaces.filter { retired.contains($0.nodeID) }
            let changed = replaces != entry.replaces
            entry.replaces = replaces
            entry.settled = true
            entries[key] = entry
            return changed ? replaces : nil
        }
    }

    public func evidence(for key: PendingSourceKey, revision: UploadBackupRevision) -> PendingUploadEvidence? {
        lock.withLock {
            entries[Key(source: key, revision: revision)].map {
                PendingUploadEvidence(key: key, revision: revision, replaces: $0.replaces)
            }
        }
    }

    public func replacementHandoffs() -> [PendingReplacementHandoff] {
        lock.withLock {
            entries.compactMap { key, entry in
                entry.remote.map {
                    PendingReplacementHandoff(
                        evidence: PendingUploadEvidence(
                            key: key.source, revision: key.revision, replaces: entry.replaces),
                        remote: $0, settled: entry.settled)
                }
            }.sorted { $0.evidence.revision > $1.evidence.revision }
        }
    }

    func dropSources(_ sources: [(PendingSourceKey, UploadBackupRevision?)]) {
        let keys = Set(sources.map { $0.0 })
        lock.withLock {
            for (source, revision) in sources {
                let dropped = entries.keys.filter { $0.source == source }
                // The newest attempt is the one whose callbacks can still arrive.
                if let latest = ([revision].compactMap { $0 } + dropped.map(\.revision)).max() {
                    blocked[source] = latest
                }
            }
            for entry in entries.keys where keys.contains(entry.source) {
                entries[entry] = nil
            }
        }
    }

    /// A new attempt of a source that left the grid, for example after the person returns it to backup.
    func readmit(_ source: PendingSourceKey) {
        lock.withLock { _ = blocked.removeValue(forKey: source) }
    }

    func drop(_ revisions: [(PendingSourceKey, UploadBackupRevision)]) {
        lock.withLock {
            for (key, revision) in revisions {
                for entry in entries.keys where entry.source == key && entry.revision <= revision {
                    entries[entry] = nil
                }
            }
        }
    }
}
