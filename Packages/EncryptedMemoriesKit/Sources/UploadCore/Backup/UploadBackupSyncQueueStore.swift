import Foundation
import PhotosCore
import SQLite3

/// Persistent sync work queue (`upload-backup-sync-queue-v1.sqlite`). The queue stores source
/// identities and revisions, not temporary export URLs; platform adapters rematerialize resources
/// when work resumes after a launch, background wake, or extension invocation.
public final class UploadBackupSyncQueueManifestStore: UploadBackupSyncQueueStore, @unchecked Sendable {
    public static let databaseFileName = "upload-backup-sync-queue-v1.sqlite"

    private static let schemaVersion = 2
    private static let catalogReplayStateKey = "catalog_replay_state"
    private var db: OpaquePointer?
    private var operationFailed = false
    private let lock = NSLock()

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // This queue can contain the only durable receipt for a remotely committed upload.
        // Open failures must therefore fail closed and leave the database untouched for a
        // compatible future build or explicit recovery. Never replace it with an empty queue.
        guard let handle = Self.openOnce(url: url, policy: policy) else { return nil }
        db = handle
    }

    deinit { close() }

    public func isOperational() -> Bool {
        lock.withLock {
            guard db != nil, !operationFailed else { return false }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT 1;", -1, &stmt, nil) == SQLITE_OK else {
                operationFailed = true
                return false
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                operationFailed = true
                return false
            }
            return true
        }
    }

    public func close() {
        lock.withLock {
            guard db != nil else { return }
            sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
            sqlite3_close(db)
            db = nil
        }
    }

    @discardableResult
    public func upsert(_ entry: UploadBackupSyncQueueEntry) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK) else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            bind(entry, to: stmt)
            return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    @discardableResult
    public func upsertBatch(_ entries: [UploadBackupSyncQueueEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK),
                requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_finalize(stmt)
                return false
            }
            defer { sqlite3_finalize(stmt) }

            var didPersist = true
            for entry in entries {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bind(entry, to: stmt)
                guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else {
                    didPersist = false
                    break
                }
            }
            guard didPersist,
                requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    public func entry(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupSyncQueueEntry? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT original_filename, byte_count, state, attempts, last_error, updated_at,
                               remote_commit_reconciliation
                        FROM backup_sync_queue
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source.kind.rawValue)
            bindText(stmt, 2, source.identifier)
            bindText(stmt, 3, source.resource.rawValue)
            sqlite3_bind_int64(stmt, 4, revision.rawValue)
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                return row(stmt, source: source, revision: revision)
            }
            if result != SQLITE_DONE { operationFailed = true }
            return nil
        }
    }

    public func nextRunnable(limit: Int) -> [UploadBackupSyncQueueEntry] {
        let clampedLimit = max(1, limit)
        return lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                               state, attempts, last_error, updated_at, remote_commit_reconciliation
                        FROM backup_sync_queue
                        WHERE state IN ('discovered', 'queuedForUpload', 'needsRemoteReconciliation')
                        ORDER BY revision_us DESC, updated_at ASC
                        LIMIT ?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(clampedLimit))
            var entries: [UploadBackupSyncQueueEntry] = []
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                    operationFailed = true
                    return []
                }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3))
                entries.append(row(stmt, source: source, revision: revision, offset: 4))
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return [] }
            return entries
        }
    }

    public func nextRunnableDate() -> Date? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT MIN(updated_at) FROM backup_sync_queue "
                            + "WHERE state IN ('discovered', 'queuedForUpload', 'needsRemoteReconciliation');",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            let result = sqlite3_step(stmt)
            guard requireOperational(result == SQLITE_ROW) else { return nil }
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
                return nil
            }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    public func earliestRunnableEntry() -> UploadBackupSyncQueueEntry? {
        earliestEntry(whereClause: "state IN ('discovered', 'queuedForUpload', 'needsRemoteReconciliation')")
    }

    public func earliestEntry(in state: UploadBackupSyncQueueState) -> UploadBackupSyncQueueEntry? {
        earliestEntry(whereClause: "state='\(state.rawValue)'")
    }

    public func containsAny(in states: [UploadBackupSyncQueueState]) -> Bool {
        guard !states.isEmpty else { return false }
        let values = states.map { "'\($0.rawValue)'" }.joined(separator: ",")
        return lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db, "SELECT 1 FROM backup_sync_queue WHERE state IN (\(values)) LIMIT 1;", -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW { return true }
            if result != SQLITE_DONE { operationFailed = true }
            return false
        }
    }

    public func claimRunnable(limit: Int, claimedAt: Date) -> [UploadBackupSyncQueueEntry] {
        let clampedLimit = max(1, limit)
        return lock.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return []
            }
            var selected: [UploadBackupSyncQueueEntry] = []
            var selectStmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                               state, attempts, last_error, updated_at, remote_commit_reconciliation
                        FROM backup_sync_queue
                        WHERE state IN ('discovered', 'queuedForUpload', 'needsRemoteReconciliation')
                          AND updated_at <= ?
                        ORDER BY revision_us DESC, updated_at ASC
                        LIMIT ?;
                        """,
                        -1, &selectStmt, nil
                    ) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return []
            }
            sqlite3_bind_double(selectStmt, 1, claimedAt.timeIntervalSince1970)
            sqlite3_bind_int(selectStmt, 2, Int32(clampedLimit))
            var selectResult = sqlite3_step(selectStmt)
            while selectResult == SQLITE_ROW {
                guard let source = sourceFromColumns(selectStmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                    operationFailed = true
                    sqlite3_finalize(selectStmt)
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return []
                }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(selectStmt, 3))
                selected.append(row(selectStmt, source: source, revision: revision, offset: 4))
                selectResult = sqlite3_step(selectStmt)
            }
            sqlite3_finalize(selectStmt)
            guard requireOperational(selectResult == SQLITE_DONE) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return []
            }

            guard !selected.isEmpty else {
                guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return []
                }
                return []
            }

            var updateStmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue
                        SET state='checking', updated_at=?
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?
                          AND state IN ('discovered', 'queuedForUpload', 'needsRemoteReconciliation');
                        """,
                        -1, &updateStmt, nil
                    ) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return []
            }
            defer { sqlite3_finalize(updateStmt) }

            var claimed: [UploadBackupSyncQueueEntry] = []
            for entry in selected {
                sqlite3_reset(updateStmt)
                sqlite3_clear_bindings(updateStmt)
                sqlite3_bind_double(updateStmt, 1, claimedAt.timeIntervalSince1970)
                bindText(updateStmt, 2, entry.source.kind.rawValue)
                bindText(updateStmt, 3, entry.source.identifier)
                bindText(updateStmt, 4, entry.source.resource.rawValue)
                sqlite3_bind_int64(updateStmt, 5, entry.revision.rawValue)
                guard requireOperational(sqlite3_step(updateStmt) == SQLITE_DONE),
                    requireOperational(sqlite3_changes(db) > 0)
                else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return []
                }
                claimed.append(entry)
            }

            guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return []
            }
            return claimed
        }
    }

    public func entries(
        in state: UploadBackupSyncQueueState,
        updatedBefore: Date,
        limit: Int
    ) -> [UploadBackupSyncQueueEntry] {
        let clampedLimit = max(1, limit)
        return lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                               state, attempts, last_error, updated_at, remote_commit_reconciliation
                        FROM backup_sync_queue
                        WHERE state = ? AND updated_at < ?
                        ORDER BY revision_us DESC, updated_at ASC
                        LIMIT ?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, state.rawValue)
            sqlite3_bind_double(stmt, 2, updatedBefore.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(clampedLimit))
            var entries: [UploadBackupSyncQueueEntry] = []
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                    operationFailed = true
                    return []
                }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3))
                entries.append(row(stmt, source: source, revision: revision, offset: 4))
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return [] }
            return entries
        }
    }

    @discardableResult
    public func requeueStaleActive(before cutoff: Date, updatedAt: Date) -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue SET
                          state = CASE state
                            WHEN 'checking' THEN CASE
                              WHEN remote_commit_reconciliation IS NOT NULL THEN 'needsRemoteReconciliation'
                              ELSE 'discovered'
                            END
                            WHEN 'hashing' THEN 'discovered'
                            WHEN 'duplicateChecking' THEN 'discovered'
                            WHEN 'uploading' THEN 'queuedForUpload'
                            WHEN 'finalizing' THEN 'queuedForUpload'
                            ELSE state
                          END,
                          updated_at = ?
                        WHERE updated_at < ?
                          AND state IN ('checking', 'hashing', 'duplicateChecking', 'uploading', 'finalizing');
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, updatedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSince1970)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    /// Resets every parked `.failed` row back to runnable with a fresh retry budget. Called when
    /// the user explicitly asks to back up again (or re-enables backup), so a manual "back up now"
    /// actually retries the items behind a "needs attention" state instead of being a no-op.
    @discardableResult
    public func requeueFailed(updatedAt: Date) -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue
                        SET state = 'discovered', attempts = 0, last_error = NULL, updated_at = ?
                        WHERE state = 'failed';
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, updatedAt.timeIntervalSince1970)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    /// Atomic manual retry: failed work receives a fresh retry budget, while draft/network-backed-off
    /// work keeps its attempt history but becomes due now. Successful and non-retryable rows never move.
    @discardableResult
    public func makeRetryableWorkEligible(updatedAt: Date) -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue SET
                          state = CASE
                            WHEN state IN ('failed', 'blockedByDraft') THEN 'discovered'
                            ELSE state
                          END,
                          attempts = CASE WHEN state = 'failed' THEN 0 ELSE attempts END,
                          last_error = NULL,
                          updated_at = ?
                        WHERE state IN (
                          'failed', 'blockedByDraft', 'discovered', 'queuedForUpload',
                          'needsRemoteReconciliation'
                        );
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, updatedAt.timeIntervalSince1970)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    @discardableResult
    public func updateState(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState,
        attempts: Int?,
        lastError: String?,
        updatedAt: Date
    ) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue SET
                          state=?,
                          attempts=COALESCE(?, attempts),
                          last_error=?,
                          remote_commit_reconciliation=CASE
                            WHEN ?='needsRemoteReconciliation' THEN remote_commit_reconciliation
                            ELSE NULL
                          END,
                          updated_at=?
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, state.rawValue)
            if let attempts {
                sqlite3_bind_int(stmt, 2, Int32(max(0, attempts)))
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            bindNullableText(stmt, 3, lastError)
            bindText(stmt, 4, state.rawValue)
            sqlite3_bind_double(stmt, 5, updatedAt.timeIntervalSince1970)
            bindText(stmt, 6, source.kind.rawValue)
            bindText(stmt, 7, source.identifier)
            bindText(stmt, 8, source.resource.rawValue)
            sqlite3_bind_int64(stmt, 9, revision.rawValue)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return false }
            return sqlite3_changes(db) > 0
        }
    }

    @discardableResult
    public func markNeedsRemoteReconciliation(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        reconciliation: UploadRemoteCommitReconciliation,
        lastError: String?,
        updatedAt: Date
    ) -> Bool {
        guard let payload = try? JSONEncoder().encode(reconciliation) else { return false }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue SET
                          state='needsRemoteReconciliation',
                          last_error=?,
                          remote_commit_reconciliation=?,
                          updated_at=?
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindNullableText(stmt, 1, lastError)
            _ = payload.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, 2, bytes.baseAddress, Int32(bytes.count), transient)
            }
            sqlite3_bind_double(stmt, 3, updatedAt.timeIntervalSince1970)
            bindText(stmt, 4, source.kind.rawValue)
            bindText(stmt, 5, source.identifier)
            bindText(stmt, 6, source.resource.rawValue)
            sqlite3_bind_int64(stmt, 7, revision.rawValue)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return false }
            return sqlite3_changes(db) > 0
        }
    }

    @discardableResult
    public func remove(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        DELETE FROM backup_sync_queue
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source.kind.rawValue)
            bindText(stmt, 2, source.identifier)
            bindText(stmt, 3, source.resource.rawValue)
            sqlite3_bind_int64(stmt, 4, revision.rawValue)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return false }
            return sqlite3_changes(db) > 0
        }
    }

    @discardableResult
    public func removeSources(kind: UploadSourceIdentity.Kind, identifiers: [String]) -> Int {
        let identifiers = Array(Set(identifiers))
        guard !identifiers.isEmpty else { return 0 }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "DELETE FROM backup_sync_queue WHERE source_kind=? AND source_id=?;",
                        -1, &stmt, nil
                    ) == SQLITE_OK),
                requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_finalize(stmt)
                return 0
            }
            defer { sqlite3_finalize(stmt) }

            var removed = 0
            for identifier in identifiers {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, kind.rawValue)
                bindText(stmt, 2, identifier)
                guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return 0
                }
                removed += Int(sqlite3_changes(db))
            }
            guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return 0
            }
            return removed
        }
    }

    /// Removes folder-backup rows that no longer belong to any registered folder root.
    /// Photo-library rows use a different source kind and are never affected.
    @discardableResult
    public func removeFileSources(outsideRootPaths rootPaths: [String]) -> Int {
        let roots = Array(
            Set(
                rootPaths.map {
                    URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
                }))
        if roots.contains("/") { return 0 }

        return lock.withLock {
            var sql = "DELETE FROM backup_sync_queue WHERE source_kind=?"
            if !roots.isEmpty {
                let retainedRootClauses = Array(
                    repeating: "(source_id=? OR substr(source_id, 1, length(?)+1)=? || '/')",
                    count: roots.count
                )
                sql += " AND NOT (\(retainedRootClauses.joined(separator: " OR ")))"
            }
            sql += ";"

            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK) else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, 1, UploadSourceIdentity.Kind.fileURL.rawValue)
            var binding: Int32 = 2
            for root in roots {
                bindText(stmt, binding, root)
                bindText(stmt, binding + 1, root)
                bindText(stmt, binding + 2, root)
                binding += 3
            }
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    public func summary() -> UploadBackupSyncQueueSummary {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT state, COUNT(*) FROM backup_sync_queue GROUP BY state;",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return UploadBackupSyncQueueSummary() }
            defer { sqlite3_finalize(stmt) }
            var summary = UploadBackupSyncQueueSummary()
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let raw = columnText(stmt, 0),
                    let state = UploadBackupSyncQueueState(rawValue: raw)
                else {
                    operationFailed = true
                    return UploadBackupSyncQueueSummary()
                }
                summary.include(state, count: Int(sqlite3_column_int(stmt, 1)))
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return UploadBackupSyncQueueSummary() }
            return summary
        }
    }

    public func count() -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM backup_sync_queue;", -1, &stmt, nil) == SQLITE_OK
                )
            else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard requireOperational(sqlite3_step(stmt) == SQLITE_ROW) else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// State of the one-time catalog replay used only when this queue DB was reset independently of
    /// the durable photo catalog. Stored in the queue DB itself: a reset naturally clears the marker
    /// and requests another rebuild, while ordinary row removal does not.
    public func catalogReplayState() -> UploadBackupCatalogReplayState {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db, "SELECT value FROM backup_sync_queue_info WHERE key=?;", -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return .notStarted }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, Self.catalogReplayStateKey)
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return .notStarted }
            guard requireOperational(result == SQLITE_ROW) else { return .notStarted }
            return UploadBackupCatalogReplayState(rawValue: Int(sqlite3_column_int(stmt, 0))) ?? .notStarted
        }
    }

    @discardableResult
    public func setCatalogReplayState(_ state: UploadBackupCatalogReplayState) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "INSERT INTO backup_sync_queue_info(key, value) VALUES(?, ?) "
                            + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, Self.catalogReplayStateKey)
            sqlite3_bind_int(stmt, 2, Int32(state.rawValue))
            return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    public func runtimeIssue(for key: BackupRuntimeIssueKey) -> BackupIssueRecord? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db, "SELECT value FROM backup_sync_runtime_issue WHERE key=?;", -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key.rawValue)
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW { return BackupIssueRecord.decode(columnText(stmt, 0)) }
            if result != SQLITE_DONE { operationFailed = true }
            return nil
        }
    }

    @discardableResult
    public func setRuntimeIssue(_ issue: BackupIssueRecord?, for key: BackupRuntimeIssueKey) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            if let issue {
                guard
                    requireOperational(
                        sqlite3_prepare_v2(
                            db,
                            "INSERT INTO backup_sync_runtime_issue(key, value) VALUES(?, ?) "
                                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                            -1, &stmt, nil
                        ) == SQLITE_OK)
                else { return false }
                bindText(stmt, 1, key.rawValue)
                bindText(stmt, 2, issue.persistedValue)
            } else {
                guard
                    requireOperational(
                        sqlite3_prepare_v2(
                            db, "DELETE FROM backup_sync_runtime_issue WHERE key=?;", -1, &stmt, nil
                        ) == SQLITE_OK)
                else { return false }
                bindText(stmt, 1, key.rawValue)
            }
            defer { sqlite3_finalize(stmt) }
            return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    private static let upsertSQL = """
        INSERT INTO backup_sync_queue(
          source_kind, source_id, resource, revision_us, original_filename,
          byte_count, state, attempts, last_error, updated_at, remote_commit_reconciliation
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(source_kind, source_id, resource, revision_us) DO UPDATE SET
          original_filename=excluded.original_filename,
          byte_count=excluded.byte_count,
          state=CASE
            WHEN backup_sync_queue.state IN (
              'discovered','queuedForUpload','failed','paused',
              'sourceMissing','blockedByDraft','skippedRemoteDeletion'
            ) THEN excluded.state
            ELSE backup_sync_queue.state
          END,
          attempts=CASE
            WHEN backup_sync_queue.state IN (
              'discovered','queuedForUpload','failed','paused',
              'sourceMissing','blockedByDraft','skippedRemoteDeletion'
            ) THEN excluded.attempts
            ELSE backup_sync_queue.attempts
          END,
          last_error=CASE
            WHEN backup_sync_queue.state IN (
              'discovered','queuedForUpload','failed','paused',
              'sourceMissing','blockedByDraft','skippedRemoteDeletion'
            ) THEN excluded.last_error
            ELSE backup_sync_queue.last_error
          END,
          remote_commit_reconciliation=CASE
            WHEN backup_sync_queue.state='needsRemoteReconciliation'
              THEN backup_sync_queue.remote_commit_reconciliation
            ELSE excluded.remote_commit_reconciliation
          END,
          updated_at=CASE
            WHEN backup_sync_queue.state='needsRemoteReconciliation'
              THEN backup_sync_queue.updated_at
            ELSE excluded.updated_at
          END;
        """

    private static func openOnce(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA busy_timeout=\(policy.busyTimeoutMs);", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA cache_size=-\(max(0, policy.cacheSizeKiB));", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA mmap_size=\(max(0, policy.mmapBytes));", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA journal_size_limit=\(policy.journalSizeLimitBytes);", nil, nil, nil)

        let schema = """
            CREATE TABLE IF NOT EXISTS backup_sync_queue_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS backup_sync_runtime_issue(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS backup_sync_queue(
              source_kind       TEXT NOT NULL,
              source_id         TEXT NOT NULL,
              resource          TEXT NOT NULL,
              revision_us       INTEGER NOT NULL,
              original_filename TEXT NOT NULL,
              byte_count        INTEGER,
              state             TEXT NOT NULL,
              attempts          INTEGER NOT NULL,
              last_error        TEXT,
              updated_at        REAL NOT NULL,
              remote_commit_reconciliation BLOB,
              PRIMARY KEY(source_kind, source_id, resource, revision_us)
            );
            CREATE INDEX IF NOT EXISTS backup_sync_queue_runnable_idx
              ON backup_sync_queue(state, updated_at);
            CREATE INDEX IF NOT EXISTS backup_sync_queue_priority_idx
              ON backup_sync_queue(state, revision_us DESC);
            CREATE INDEX IF NOT EXISTS backup_sync_queue_source_idx
              ON backup_sync_queue(source_kind, source_id, resource);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK,
            verifyAndStampVersion(handle)
        else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    private static func verifyAndStampVersion(_ handle: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(handle, "SELECT value FROM backup_sync_queue_info WHERE key='schema';", -1, &stmt, nil)
                == SQLITE_OK
        else {
            return false
        }
        var onDisk: Int?
        if sqlite3_step(stmt) == SQLITE_ROW { onDisk = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        if let onDisk, onDisk != schemaVersion { return false }
        return sqlite3_exec(
            handle,
            "INSERT INTO backup_sync_queue_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    private func bind(_ entry: UploadBackupSyncQueueEntry, to stmt: OpaquePointer?) {
        bindText(stmt, 1, entry.source.kind.rawValue)
        bindText(stmt, 2, entry.source.identifier)
        bindText(stmt, 3, entry.source.resource.rawValue)
        sqlite3_bind_int64(stmt, 4, entry.revision.rawValue)
        bindText(stmt, 5, entry.originalFilename)
        if let byteCount = entry.byteCount {
            sqlite3_bind_int64(stmt, 6, byteCount)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        bindText(stmt, 7, entry.state.rawValue)
        sqlite3_bind_int(stmt, 8, Int32(entry.attempts))
        bindNullableText(stmt, 9, entry.lastError)
        sqlite3_bind_double(stmt, 10, entry.updatedAt.timeIntervalSince1970)
        if let reconciliation = entry.remoteCommitReconciliation,
            let data = try? JSONEncoder().encode(reconciliation)
        {
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, 11, bytes.baseAddress, Int32(bytes.count), transient)
            }
        } else {
            sqlite3_bind_null(stmt, 11)
        }
    }

    private func row(
        _ stmt: OpaquePointer?,
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        offset: Int32 = 0
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: source,
            revision: revision,
            originalFilename: columnText(stmt, offset) ?? "",
            byteCount: sqlite3_column_type(stmt, offset + 1) == SQLITE_NULL
                ? nil : sqlite3_column_int64(stmt, offset + 1),
            state: UploadBackupSyncQueueState(rawValue: columnText(stmt, offset + 2) ?? "") ?? .failed,
            attempts: Int(sqlite3_column_int(stmt, offset + 3)),
            lastError: columnText(stmt, offset + 4),
            remoteCommitReconciliation: reconciliation(stmt, column: offset + 6),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, offset + 5))
        )
    }

    private func sourceFromColumns(
        _ stmt: OpaquePointer?,
        kindColumn: Int32,
        idColumn: Int32,
        resourceColumn: Int32
    ) -> UploadSourceIdentity? {
        guard let kindRaw = columnText(stmt, kindColumn),
            let kind = UploadSourceIdentity.Kind(rawValue: kindRaw),
            let id = columnText(stmt, idColumn),
            let resourceRaw = columnText(stmt, resourceColumn)
        else {
            return nil
        }
        let resource = UploadSourceIdentity.Resource(rawValue: resourceRaw)
        return UploadSourceIdentity(kind: kind, identifier: id, resource: resource)
    }

    private func earliestEntry(whereClause: String) -> UploadBackupSyncQueueEntry? {
        lock.withLock {
            var stmt: OpaquePointer?
            let sql = """
                SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                       state, attempts, last_error, updated_at, remote_commit_reconciliation
                FROM backup_sync_queue WHERE \(whereClause)
                ORDER BY updated_at ASC LIMIT 1;
                """
            guard requireOperational(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK) else { return nil }
            defer { sqlite3_finalize(stmt) }
            let result = sqlite3_step(stmt)
            guard result == SQLITE_ROW else {
                if result != SQLITE_DONE { operationFailed = true }
                return nil
            }
            guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                operationFailed = true
                return nil
            }
            return row(
                stmt,
                source: source,
                revision: UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3)),
                offset: 4
            )
        }
    }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bindNullableText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
            let text = sqlite3_column_text(stmt, index)
        else {
            return nil
        }
        return String(cString: text)
    }

    private func reconciliation(
        _ stmt: OpaquePointer?,
        column: Int32
    ) -> UploadRemoteCommitReconciliation? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
            let bytes = sqlite3_column_blob(stmt, column)
        else {
            return nil
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
        return try? JSONDecoder().decode(UploadRemoteCommitReconciliation.self, from: data)
    }

    @discardableResult
    private func requireOperational(_ condition: Bool) -> Bool {
        if !condition { operationFailed = true }
        return condition
    }
}
