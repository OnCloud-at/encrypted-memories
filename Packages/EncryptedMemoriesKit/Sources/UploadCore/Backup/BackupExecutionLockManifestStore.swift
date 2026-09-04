import Foundation
import PhotosCore
import SQLite3

/// Persistent backup execution lock (`backup-execution-lock-v1.sqlite`). One row per named lock.
/// A future, corrupt, locked, or temporarily unavailable store fails closed and preserves ownership.
///
/// Staleness is lease-based: `acquire` treats an existing lock whose `heartbeatAt` is older than
/// `leaseInterval` before `now()` as abandoned and takes it. `recoverStaleLocks(olderThan:)` is the
/// explicit primitive the runner calls before draining so recovery provably precedes the drain.
public final class BackupExecutionLockManifestStore: BackupExecutionLockStore, @unchecked Sendable {
    public static let databaseFileName = "backup-execution-lock-v1.sqlite"
    /// Default lease: a healthy owner heartbeats well inside this; a crashed one is recoverable
    /// after it. Injected so tests and platforms can tune it.
    public static let defaultLeaseInterval: TimeInterval = 120

    private static let schemaVersion = 1
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let lockName: String
    private let leaseInterval: TimeInterval
    private let now: @Sendable () -> Date

    public init?(
        url: URL,
        policy: LibraryDatabasePolicy = .conservative,
        lockName: String = "photoBackup",
        leaseInterval: TimeInterval = defaultLeaseInterval,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.lockName = lockName.isEmpty ? "photoBackup" : lockName
        self.leaseInterval = max(1, leaseInterval)
        self.now = now
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = Self.openVerified(url: url, policy: policy) else { return nil }
        db = handle
    }

    deinit { close() }

    public func close() {
        lock.withLock {
            guard db != nil else { return }
            sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
            sqlite3_close(db)
            db = nil
        }
    }

    public func currentLock() -> BackupExecutionLock? {
        lock.withLock { readLock() }
    }

    public func acquire(
        owner: BackupExecutionOwner,
        runID: String,
        phase: String?,
        processContext: String?
    ) -> BackupLockAcquisition {
        lock.withLock {
            // The execution lock is durable across store instances and processes, so the read/decide/write
            // sequence must be one SQLite write transaction. An instance-local NSLock alone allows two
            // connections to both observe an empty row and both report acquisition after racing UPSERTs.
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                return .unavailable
            }
            var committed = false
            defer {
                if !committed {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                }
            }

            let moment = now()
            if let existing = readLock() {
                let isOurs = existing.runID == runID
                let isStale = existing.heartbeatAt < moment.addingTimeInterval(-leaseInterval)
                guard isOurs || isStale else {
                    committed = sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK
                    return committed ? .busy(existing) : .unavailable
                }
            }
            let taken = BackupExecutionLock(
                owner: owner,
                runID: runID,
                acquiredAt: moment,
                heartbeatAt: moment,
                phase: phase,
                processContext: processContext
            )
            guard writeLock(taken), sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                return .unavailable
            }
            committed = true
            return .acquired(taken)
        }
    }

    @discardableResult
    public func heartbeat(runID: String, phase: String?) -> Bool {
        lock.withLock {
            guard let existing = readLock(), existing.runID == runID else { return false }
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "UPDATE backup_execution_lock SET heartbeat_at=?, phase=? WHERE lock_name=? AND run_id=?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, now().timeIntervalSince1970)
            bindNullableText(stmt, 2, phase ?? existing.phase)
            bindText(stmt, 3, lockName)
            bindText(stmt, 4, runID)
            return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
        }
    }

    @discardableResult
    public func release(runID: String) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "DELETE FROM backup_execution_lock WHERE lock_name=? AND run_id=?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, lockName)
            bindText(stmt, 2, runID)
            return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
        }
    }

    @discardableResult
    public func recoverStaleLocks(olderThan cutoff: Date) -> [BackupExecutionLock] {
        lock.withLock {
            guard let existing = readLock(), existing.heartbeatAt < cutoff else { return [] }
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "DELETE FROM backup_execution_lock WHERE lock_name=? AND heartbeat_at < ?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, lockName)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 else { return [] }
            return [existing]
        }
    }

    /// Recovers a lock left by a previous process on the same platform after an OS kill / force quit.
    ///
    /// Lease-based recovery is still the primary safety net. This narrower recovery only fires when
    /// both process contexts have the expected `platform/pid-N` shape, the platform matches, the PID
    /// differs, and the caller proves that old PID is no longer alive. A live owner is never stolen.
    @discardableResult
    public func recoverAbandonedProcessLocks(
        currentProcessContext: String,
        isProcessAlive: (Int32) -> Bool
    ) -> [BackupExecutionLock] {
        lock.withLock {
            guard let existing = readLock(),
                let old = Self.parseProcessContext(existing.processContext),
                let current = Self.parseProcessContext(currentProcessContext),
                old.platform == current.platform,
                old.pid != current.pid,
                !isProcessAlive(old.pid)
            else {
                return []
            }
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "DELETE FROM backup_execution_lock WHERE lock_name=? AND run_id=?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, lockName)
            bindText(stmt, 2, existing.runID)
            guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 else { return [] }
            return [existing]
        }
    }

    // MARK: - Read/write (must be called under `lock`)

    private func readLock() -> BackupExecutionLock? {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                SELECT owner, run_id, acquired_at, heartbeat_at, phase, process_context
                FROM backup_execution_lock WHERE lock_name=?;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, lockName)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return BackupExecutionLock(
            owner: BackupExecutionOwner(rawValue: columnText(stmt, 0) ?? BackupExecutionOwner.foreground.rawValue),
            runID: columnText(stmt, 1) ?? "",
            acquiredAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
            heartbeatAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
            phase: columnText(stmt, 4),
            processContext: columnText(stmt, 5)
        )
    }

    private func writeLock(_ lock: BackupExecutionLock) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                INSERT INTO backup_execution_lock(
                  lock_name, owner, run_id, acquired_at, heartbeat_at, phase, process_context
                ) VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(lock_name) DO UPDATE SET
                  owner=excluded.owner,
                  run_id=excluded.run_id,
                  acquired_at=excluded.acquired_at,
                  heartbeat_at=excluded.heartbeat_at,
                  phase=excluded.phase,
                  process_context=excluded.process_context;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, lockName)
        bindText(stmt, 2, lock.owner.rawValue)
        bindText(stmt, 3, lock.runID)
        sqlite3_bind_double(stmt, 4, lock.acquiredAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, lock.heartbeatAt.timeIntervalSince1970)
        bindNullableText(stmt, 6, lock.phase)
        bindNullableText(stmt, 7, lock.processContext)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Open / schema

    private static func openVerified(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        openOnce(url: url, policy: policy)
    }

    private static func openOnce(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        let schema = """
            CREATE TABLE IF NOT EXISTS backup_execution_lock_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS backup_execution_lock(
              lock_name       TEXT PRIMARY KEY,
              owner           TEXT NOT NULL,
              run_id          TEXT NOT NULL,
              acquired_at     REAL NOT NULL,
              heartbeat_at    REAL NOT NULL,
              phase           TEXT,
              process_context TEXT
            );
            """

        let compatibility = SQLiteStoreSchemaGate.compatibility(
            at: url,
            schemaSQL: schema,
            busyTimeoutMs: policy.busyTimeoutMs,
            versionIsCurrent: verifyVersion
        )
        guard compatibility == .empty || compatibility == .current else { return nil }
        var handle: OpaquePointer?
        let flags =
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            | (compatibility == .empty ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, Int32(clamping: policy.busyTimeoutMs))
        switch compatibility {
        case .empty:
            SQLiteStoreSchemaGate.configureConnection(handle, policy: policy)
            guard
                SQLiteStoreSchemaGate.initializeCurrentSchema(
                    handle,
                    schemaSQL: schema,
                    stamp: { stampVersion(handle) }
                )
            else {
                sqlite3_close(handle)
                return nil
            }
        case .current:
            guard verifyVersion(handle),
                SQLiteStoreSchemaGate.matchesCurrentSchema(handle, schemaSQL: schema)
            else {
                sqlite3_close(handle)
                return nil
            }
            SQLiteStoreSchemaGate.configureConnection(handle, policy: policy)
        case .incompatible, .unavailable:
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    private static func verifyVersion(_ handle: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                handle, "SELECT value FROM backup_execution_lock_info WHERE key='schema';", -1, &stmt, nil) == SQLITE_OK
        else {
            return false
        }
        var onDisk: Int?
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW { onDisk = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        return result == SQLITE_ROW && onDisk == schemaVersion
    }

    private static func stampVersion(_ handle: OpaquePointer?) -> Bool {
        return sqlite3_exec(
            handle,
            "INSERT INTO backup_execution_lock_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    private static func parseProcessContext(_ raw: String?) -> (platform: String, pid: Int32)? {
        guard let raw,
            let slash = raw.firstIndex(of: "/")
        else { return nil }
        let platform = String(raw[..<slash])
        let suffix = raw[raw.index(after: slash)...]
        guard suffix.hasPrefix("pid-"),
            let pid = Int32(suffix.dropFirst(4)),
            !platform.isEmpty,
            pid > 0
        else { return nil }
        return (platform, pid)
    }

    // MARK: - Bind/column helpers

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
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let text = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: text)
    }
}
