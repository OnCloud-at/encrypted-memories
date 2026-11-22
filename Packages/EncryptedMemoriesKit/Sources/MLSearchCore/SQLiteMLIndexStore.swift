import Foundation
import PhotosCore
import SQLite3

/// Local derived index with WAL, batched transactions and authenticated vector encryption.
/// Corrupt or wrong-key rows are ignored and can be rebuilt from the media cache.
///
/// Rows persist vectors as IEEE-754 binary16 (`MLFloat16Codec`): half the disk footprint and
/// read/write I/O of Float32 at ~2^-11 relative precision; far below ranking noise for
/// normalized CLIP-family embeddings. The in-memory query blocks stay Float32; widening
/// happens once per bounded page. A `user_version` mismatch resets the ML-only schema
/// (vectors are derived data rebuilt from the media cache, so no migration machinery is needed).
public final class SQLiteMLIndexStore: MLIndexStore, @unchecked Sendable {
    public static let databaseFileName = "ml-search-index-v1.sqlite"

    // Derived state never migrates. Version 5 forces one clean rebuild for the source-aware inventory cut.
    private static let userVersion = SQLiteUserVersion(version: 5)
    private static let membershipChunkSize = 200
    /// The one precision this build writes and reads. Rows with any other precision are
    /// invisible (skipped by the epoch-read predicate), never misinterpreted.
    private static let precision = MLEmbeddingPrecision.float16

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let cipher: any MLVectorCipher

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative, cipher: any MLVectorCipher) {
        self.cipher = cipher
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

    // MARK: - Writes

    @discardableResult
    public func upsert(_ records: [MLEmbeddingRecord]) -> MLIndexBatchReport {
        guard !records.isEmpty else { return MLIndexBatchReport() }
        var indexed = 0
        var skipped = 0
        var rejected = 0
        var failed = 0
        var changedDescriptors: Set<MLModelDescriptor> = []

        lock.withLock {
            guard db != nil else {
                failed = records.count
                return
            }
            var stmt: OpaquePointer?
            var clearFailureStmt: OpaquePointer?
            defer {
                sqlite3_finalize(stmt)
                sqlite3_finalize(clearFailureStmt)
            }
            // A failed begin, prepare, failure cleanup, generation bump or commit stores nothing. Every record not
            // rejected before the failure then counts as transient. A failed insert bind or insert step counts only that
            // record, unless the failed step ended the transaction.
            let committed = SQLiteTransaction.immediate(db) {
                guard
                    sqlite3_prepare_v2(
                        db,
                        """
                        INSERT OR IGNORE INTO ml_embeddings(
                          volume_id, node_id, model_identifier, model_version,
                          embedding_dimension, embedding_precision, vector, capture_time, indexed_at
                        ) VALUES(?,?,?,?,?,?,?,?,?);
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK
                else { return false }
                guard
                    sqlite3_prepare_v2(
                        db,
                        "DELETE FROM ml_failures WHERE model_identifier=? AND model_version=? AND volume_id=? AND node_id=?;",
                        -1, &clearFailureStmt, nil
                    ) == SQLITE_OK
                else { return false }

                for record in records {
                    guard record.isDimensionConsistent else {
                        rejected += 1
                        continue
                    }
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    // A failed bind leaves its parameter NULL, and OR IGNORE would skip that row as already indexed
                    // (#1194).
                    guard bindUID(stmt, 1, record.uid), SQLiteBinding.bindText(stmt, 3, record.descriptor.identifier),
                        SQLiteBinding.bindText(stmt, 6, Self.precision.rawValue)
                    else {
                        failed += 1
                        continue
                    }
                    sqlite3_bind_int64(stmt, 4, Int64(record.descriptor.version))
                    sqlite3_bind_int64(stmt, 5, Int64(record.descriptor.embeddingDimension))
                    let plaintext = MLFloat16Codec.encodeLittleEndian(record.vector)
                    let ciphertext: Data
                    do {
                        ciphertext = try cipher.seal(
                            plaintext,
                            context: MLVectorCipherContext(uid: record.uid, descriptor: record.descriptor)
                        )
                    } catch {
                        failed += 1
                        continue
                    }
                    guard SQLiteBinding.bindBlob(stmt, 7, ciphertext) else {
                        failed += 1
                        continue
                    }
                    if let captureTime = record.captureTime {
                        sqlite3_bind_double(stmt, 8, captureTime.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(stmt, 8)
                    }
                    sqlite3_bind_double(stmt, 9, record.timestamp.timeIntervalSince1970)

                    if sqlite3_step(stmt) == SQLITE_DONE {
                        // OR IGNORE: 0 changes means the unique key already existed (first write wins).
                        if sqlite3_changes(db) > 0 {
                            indexed += 1
                            changedDescriptors.insert(record.descriptor)
                        } else {
                            skipped += 1
                        }
                        sqlite3_reset(clearFailureStmt)
                        sqlite3_clear_bindings(clearFailureStmt)
                        sqlite3_bind_int64(clearFailureStmt, 2, Int64(record.descriptor.version))
                        guard SQLiteBinding.bindText(clearFailureStmt, 1, record.descriptor.identifier),
                            bindUID(clearFailureStmt, 3, record.uid),
                            sqlite3_step(clearFailureStmt) == SQLITE_DONE
                        else { return false }
                    } else {
                        // SQLite can end the whole transaction after a failed step, for example on a full disk. The
                        // later writes would then commit one by one, so the batch fails and stores nothing. A busy step
                        // keeps the transaction, but cannot occur here: BEGIN IMMEDIATE already holds the write lock.
                        guard sqlite3_get_autocommit(db) == 0 else { return false }
                        failed += 1
                    }
                }
                for descriptor in changedDescriptors where !bumpGenerationLocked(for: descriptor) {
                    return false
                }
                return true
            }
            if !committed {
                indexed = 0
                skipped = 0
                failed = records.count - rejected
            }
        }

        return MLIndexBatchReport(
            total: records.count,
            indexed: indexed,
            skippedAlreadyIndexed: skipped,
            permanentFailure: rejected,
            transientFailure: failed
        )
    }

    public func remove(uids: [PhotoUID], descriptor: MLModelDescriptor) {
        guard !uids.isEmpty else { return }
        lock.withLock { _ = removeTrackedUIDsLocked(uids, descriptor: descriptor) }
    }

    @discardableResult
    public func removeAll(for descriptor: MLModelDescriptor) -> Bool {
        lock.withLock {
            guard db != nil else { return false }
            var embeddings: OpaquePointer?
            var failures: OpaquePointer?
            // The statements end after the transaction. After a failed prepare they end after the rollback; they
            // had not run. One that did not prepare finalizes as a no-op.
            defer {
                sqlite3_finalize(embeddings)
                sqlite3_finalize(failures)
            }
            return SQLiteTransaction.immediate(db) {
                guard
                    sqlite3_prepare_v2(
                        db,
                        "DELETE FROM ml_embeddings WHERE model_identifier=? AND model_version=?;",
                        -1, &embeddings, nil
                    ) == SQLITE_OK,
                    sqlite3_prepare_v2(
                        db,
                        "DELETE FROM ml_failures WHERE model_identifier=? AND model_version=?;",
                        -1, &failures, nil
                    ) == SQLITE_OK
                else { return false }

                guard bindDescriptor(embeddings, descriptor), sqlite3_step(embeddings) == SQLITE_DONE else {
                    return false
                }
                let removedEmbeddings = sqlite3_changes(db)

                return bindDescriptor(failures, descriptor) && sqlite3_step(failures) == SQLITE_DONE
                    && (removedEmbeddings == 0 || bumpGenerationLocked(for: descriptor))
            }
        }
    }

    // MARK: - Membership / coverage

    public func indexedUIDs(for descriptor: MLModelDescriptor, from uids: [PhotoUID]) throws -> Set<PhotoUID> {
        guard !uids.isEmpty else { return [] }
        var found: Set<PhotoUID> = []
        try lock.withLock {
            guard db != nil else { throw MLIndexStoreReadError.storageUnavailable }
            // Chunked row-value IN so a 100k+ membership check never builds one giant
            // statement and never loads vectors (index-only lookup).
            var start = 0
            while start < uids.count {
                let end = min(start + Self.membershipChunkSize, uids.count)
                let chunk = uids[start..<end]
                start = end

                let placeholders = Array(repeating: "(?,?)", count: chunk.count).joined(separator: ",")
                var stmt: OpaquePointer?
                guard
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT volume_id, node_id FROM ml_embeddings
                        WHERE model_identifier=? AND model_version=?
                          AND embedding_dimension=? AND embedding_precision=?
                          AND (volume_id, node_id) IN (VALUES \(placeholders));
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK
                else { throw MLIndexStoreReadError.storageUnavailable }
                defer {
                    if let stmt { sqlite3_finalize(stmt) }
                }
                guard bindEpochRead(stmt, descriptor), bindUIDs(stmt, from: 5, chunk) else {
                    throw MLIndexStoreReadError.storageUnavailable
                }
                var done = false
                while !done {
                    switch sqlite3_step(stmt) {
                    case SQLITE_ROW:
                        found.insert(PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1)))
                    case SQLITE_DONE:
                        done = true
                    default:
                        throw MLIndexStoreReadError.storageUnavailable
                    }
                }
            }
        }
        return found
    }

    @discardableResult
    public func reconcileTrackedUIDs(
        currentAuthoritativeUIDs: [PhotoUID],
        previousAuthoritativeUIDs: [PhotoUID]?,
        descriptor: MLModelDescriptor
    ) -> Bool {
        let current = Set(currentAuthoritativeUIDs)
        return lock.withLock {
            let baseline: [PhotoUID]
            if let previousAuthoritativeUIDs {
                baseline = previousAuthoritativeUIDs
            } else if let stored = allTrackedUIDsLocked(for: descriptor) {
                baseline = stored
            } else {
                return false
            }
            let removed = baseline.filter { !current.contains($0) }
            return removeTrackedUIDsLocked(removed, descriptor: descriptor)
        }
    }

    public func count(for descriptor: MLModelDescriptor) -> Int {
        lock.withLock { countLocked(for: descriptor) }
    }

    public func generation(for descriptor: MLModelDescriptor) -> UInt64 {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "SELECT generation FROM ml_epoch_state WHERE model_identifier=? AND model_version=?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard bindDescriptor(stmt, descriptor), sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return UInt64(max(0, sqlite3_column_int64(stmt, 0)))
        }
    }

    @discardableResult
    public func recordFailures(_ records: [MLIndexFailureRecord]) -> Bool {
        guard !records.isEmpty else { return true }
        return lock.withLock {
            var stmt: OpaquePointer?
            // The statement ends after the transaction; one that did not prepare finalizes as a no-op.
            defer { sqlite3_finalize(stmt) }
            // SQLite can keep a transaction open after a failed COMMIT; the shared frame then rolls it back.
            return SQLiteTransaction.immediate(db) {
                guard
                    sqlite3_prepare_v2(
                        db,
                        """
                        INSERT INTO ml_failures(
                          volume_id, node_id, model_identifier, model_version,
                          kind, reason, attempts, updated_at
                        )
                        SELECT ?,?,?,?,?,?,?,?
                        WHERE NOT EXISTS(
                          SELECT 1 FROM ml_embeddings
                          WHERE model_identifier=? AND model_version=? AND volume_id=? AND node_id=?
                        )
                        ON CONFLICT(model_identifier, model_version, volume_id, node_id) DO UPDATE SET
                          kind=excluded.kind,
                          reason=excluded.reason,
                          attempts=excluded.attempts,
                          updated_at=excluded.updated_at;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK
                else { return false }

                for record in records {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int64(stmt, 4, Int64(record.descriptor.version))
                    sqlite3_bind_int64(stmt, 7, Int64(record.attempts))
                    sqlite3_bind_double(stmt, 8, record.updatedAt.timeIntervalSince1970)
                    sqlite3_bind_int64(stmt, 10, Int64(record.descriptor.version))
                    // A failed bind leaves its parameter NULL; the write must not run (#1194).
                    guard bindUID(stmt, 1, record.uid), SQLiteBinding.bindText(stmt, 3, record.descriptor.identifier),
                        SQLiteBinding.bindText(stmt, 5, record.kind.rawValue),
                        SQLiteBinding.bindText(stmt, 6, record.reason),
                        SQLiteBinding.bindText(stmt, 9, record.descriptor.identifier), bindUID(stmt, 11, record.uid),
                        sqlite3_step(stmt) == SQLITE_DONE
                    else { return false }
                }
                return true
            }
        }
    }

    public func failureRecords(
        for descriptor: MLModelDescriptor,
        from uids: [PhotoUID]
    ) throws -> [PhotoUID: MLIndexFailureRecord] {
        guard !uids.isEmpty else { return [:] }
        return try lock.withLock {
            guard db != nil else { throw MLIndexStoreReadError.storageUnavailable }
            var found: [PhotoUID: MLIndexFailureRecord] = [:]
            var start = 0
            while start < uids.count {
                let end = min(start + Self.membershipChunkSize, uids.count)
                let chunk = uids[start..<end]
                start = end
                let placeholders = Array(repeating: "(?,?)", count: chunk.count).joined(separator: ",")
                var stmt: OpaquePointer?
                guard
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT volume_id, node_id, kind, reason, attempts, updated_at
                        FROM ml_failures
                        WHERE model_identifier=? AND model_version=?
                          AND (volume_id, node_id) IN (VALUES \(placeholders));
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK
                else { throw MLIndexStoreReadError.storageUnavailable }
                defer {
                    if let stmt { sqlite3_finalize(stmt) }
                }
                guard bindDescriptor(stmt, descriptor), bindUIDs(stmt, from: 3, chunk) else {
                    throw MLIndexStoreReadError.storageUnavailable
                }
                var done = false
                while !done {
                    switch sqlite3_step(stmt) {
                    case SQLITE_ROW:
                        let uid = PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1))
                        guard let kind = MLIndexFailureKind(rawValue: columnText(stmt, 2)) else {
                            throw MLIndexStoreReadError.storageUnavailable
                        }
                        let reason = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : columnText(stmt, 3)
                        found[uid] = MLIndexFailureRecord(
                            uid: uid,
                            descriptor: descriptor,
                            kind: kind,
                            reason: reason,
                            attempts: Int(sqlite3_column_int64(stmt, 4)),
                            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                        )
                    case SQLITE_DONE:
                        done = true
                    default:
                        throw MLIndexStoreReadError.storageUnavailable
                    }
                }
            }
            return found
        }
    }

    // MARK: - Reads

    /// Streams a deterministic keyset page into a bounded Float32 block.
    ///
    /// The cursor uses the persisted UID order instead of OFFSET, so corrupt-row deletion cannot
    /// make later pages skip rows. Only one page's widened vectors and invalid-row set exist at a time.
    public func forEachVectorBlock(
        for descriptor: MLModelDescriptor,
        maximumRows: Int,
        _ body: (MLVectorBlock) throws -> Void
    ) throws {
        guard maximumRows > 0 else { return }
        var lastUID: PhotoUID?
        while true {
            if Task.isCancelled { return }
            let page: (block: MLVectorBlock, rowCount: Int, lastUID: PhotoUID?) = try lock.withLock {
                var stmt: OpaquePointer?
                let sql: String
                if lastUID == nil {
                    sql = """
                        SELECT volume_id, node_id, vector FROM ml_embeddings
                        WHERE model_identifier=? AND model_version=? AND embedding_dimension=? AND embedding_precision=?
                        ORDER BY volume_id, node_id
                        LIMIT ?;
                        """
                } else {
                    // The composite range lets SQLite seek past the cursor instead of scanning earlier rows.
                    sql = """
                        SELECT volume_id, node_id, vector FROM ml_embeddings
                        WHERE model_identifier=? AND model_version=? AND embedding_dimension=? AND embedding_precision=?
                          AND (volume_id, node_id) > (?, ?)
                        ORDER BY volume_id, node_id
                        LIMIT ?;
                        """
                }
                guard db != nil,
                    sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
                else {
                    throw MLIndexStoreReadError.storageUnavailable
                }
                defer { sqlite3_finalize(stmt) }
                guard bindEpochRead(stmt, descriptor) else { throw MLIndexStoreReadError.storageUnavailable }
                var limitIndex: Int32 = 5
                if let lastUID {
                    guard bindUID(stmt, 5, lastUID) else { throw MLIndexStoreReadError.storageUnavailable }
                    limitIndex = 7
                }
                sqlite3_bind_int64(stmt, limitIndex, Int64(maximumRows))

                var block = MLVectorBlock(descriptor: descriptor)
                block.reserveCapacity(maximumRows)
                var invalidUIDs: Set<PhotoUID> = []
                var rowCount = 0
                var pageLastUID: PhotoUID?
                let expectedBytes = descriptor.embeddingDimension * MLFloat16Codec.bytesPerElement
                let expectedSealedBytes = cipher.sealedByteCount(forPlaintextByteCount: expectedBytes)

                readRows: while true {
                    switch sqlite3_step(stmt) {
                    case SQLITE_ROW: break
                    case SQLITE_DONE: break readRows
                    default: throw MLIndexStoreReadError.storageUnavailable
                    }
                    rowCount += 1
                    let uid = PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1))
                    pageLastUID = uid
                    let encryptedBytes = Int(sqlite3_column_bytes(stmt, 2))
                    guard encryptedBytes > 0, let blob = sqlite3_column_blob(stmt, 2) else {
                        invalidUIDs.insert(uid)
                        continue
                    }
                    if let expectedSealedBytes, encryptedBytes != expectedSealedBytes {
                        invalidUIDs.insert(uid)
                        continue
                    }
                    let ciphertext = Data(bytes: blob, count: encryptedBytes)
                    let context = MLVectorCipherContext(uid: uid, descriptor: descriptor)
                    guard let plaintext = try? cipher.open(ciphertext, context: context),
                        plaintext.count == expectedBytes
                    else {
                        invalidUIDs.insert(uid)
                        continue
                    }
                    _ = plaintext.withUnsafeBytes { raw in
                        block.append(uid: uid, rawLittleEndianFloat16: raw)
                    }
                }
                sqlite3_finalize(stmt)
                stmt = nil
                deleteInvalidRowsLocked(invalidUIDs, descriptor: descriptor)
                return (block, rowCount, pageLastUID)
            }

            // Scoring can take much longer than the SQLite read. Keep it outside the store lock so bounded
            // indexing writes and progress reads remain responsive between deterministic keyset pages.
            if !page.block.isEmpty { try body(page.block) }
            if Task.isCancelled { return }
            guard page.rowCount > 0, let pageLastUID = page.lastUID else { return }
            lastUID = pageLastUID
            if page.rowCount < maximumRows { return }
        }
    }

    // MARK: - Open / schema

    private static func openVerified(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        let schema = """
            CREATE TABLE IF NOT EXISTS ml_embeddings(
              volume_id           TEXT NOT NULL,
              node_id             TEXT NOT NULL,
              model_identifier    TEXT NOT NULL,
              model_version       INTEGER NOT NULL,
              embedding_dimension INTEGER NOT NULL,
              embedding_precision TEXT NOT NULL,
              vector              BLOB NOT NULL,
              capture_time        REAL,
              indexed_at          REAL NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS ml_embeddings_key
              ON ml_embeddings(model_identifier, model_version, volume_id, node_id);
            CREATE TABLE IF NOT EXISTS ml_failures(
              volume_id        TEXT NOT NULL,
              node_id          TEXT NOT NULL,
              model_identifier TEXT NOT NULL,
              model_version    INTEGER NOT NULL,
              kind             TEXT NOT NULL,
              reason           TEXT,
              attempts         INTEGER NOT NULL,
              updated_at       REAL NOT NULL,
              PRIMARY KEY(model_identifier, model_version, volume_id, node_id)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS ml_epoch_state(
              model_identifier TEXT NOT NULL,
              model_version    INTEGER NOT NULL,
              generation       INTEGER NOT NULL,
              PRIMARY KEY(model_identifier, model_version)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS ml_embedding_count(
              model_identifier    TEXT NOT NULL,
              model_version       INTEGER NOT NULL,
              embedding_dimension INTEGER NOT NULL,
              embedding_precision TEXT NOT NULL,
              count               INTEGER NOT NULL,
              PRIMARY KEY(model_identifier, model_version, embedding_dimension, embedding_precision)
            ) WITHOUT ROWID;
            CREATE TRIGGER IF NOT EXISTS ml_embeddings_count_insert
            AFTER INSERT ON ml_embeddings BEGIN
              INSERT INTO ml_embedding_count(
                model_identifier, model_version, embedding_dimension, embedding_precision, count
              ) VALUES(
                NEW.model_identifier, NEW.model_version, NEW.embedding_dimension, NEW.embedding_precision, 1
              ) ON CONFLICT(model_identifier, model_version, embedding_dimension, embedding_precision)
              DO UPDATE SET count=count+1;
            END;
            CREATE TRIGGER IF NOT EXISTS ml_embeddings_count_delete
            AFTER DELETE ON ml_embeddings BEGIN
              UPDATE ml_embedding_count SET count=count-1
              WHERE model_identifier=OLD.model_identifier
                AND model_version=OLD.model_version
                AND embedding_dimension=OLD.embedding_dimension
                AND embedding_precision=OLD.embedding_precision;
              DELETE FROM ml_embedding_count WHERE count=0;
            END;
            """

        return SQLiteStoreSchemaGate.openRebuildableStore(
            at: url,
            schemaSQL: schema,
            policy: policy,
            verifyVersion: userVersion.verify,
            stampVersion: userVersion.stamp
        )
    }

    // MARK: - Helpers (lock held)

    private func allTrackedUIDsLocked(for descriptor: MLModelDescriptor) -> [PhotoUID]? {
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                SELECT volume_id, node_id FROM ml_embeddings
                WHERE model_identifier=? AND model_version=?
                  AND embedding_dimension=? AND embedding_precision=?
                UNION
                SELECT volume_id, node_id FROM ml_failures
                WHERE model_identifier=? AND model_version=?
                ORDER BY volume_id, node_id;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard bindEpochRead(stmt, descriptor), SQLiteBinding.bindText(stmt, 5, descriptor.identifier) else {
            return nil
        }
        sqlite3_bind_int64(stmt, 6, Int64(descriptor.version))

        var uids: [PhotoUID] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                uids.append(PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1)))
            case SQLITE_DONE:
                return uids
            default:
                return nil
            }
        }
    }

    /// Removes tracked state in bounded SQL statements and one transaction. The caller holds `lock`.
    private func removeTrackedUIDsLocked(
        _ uids: [PhotoUID],
        descriptor: MLModelDescriptor
    ) -> Bool {
        let uniqueUIDs = Array(Set(uids))
        guard !uniqueUIDs.isEmpty else { return true }
        guard db != nil else { return false }
        return SQLiteTransaction.immediate(db) {
            guard
                let removedEmbeddings = deleteUIDRowsLocked(
                    uniqueUIDs,
                    table: "ml_embeddings",
                    descriptor: descriptor
                ),
                deleteUIDRowsLocked(
                    uniqueUIDs,
                    table: "ml_failures",
                    descriptor: descriptor
                ) != nil
            else { return false }
            return removedEmbeddings == 0 || bumpGenerationLocked(for: descriptor)
        }
    }

    /// Deletes UID rows in bounded chunks. Only fixed internal table names are accepted.
    private func deleteUIDRowsLocked(
        _ uids: [PhotoUID],
        table: String,
        descriptor: MLModelDescriptor
    ) -> Int? {
        guard table == "ml_embeddings" || table == "ml_failures" else { return nil }
        var totalChanges = 0
        var start = 0
        while start < uids.count {
            let end = min(start + Self.membershipChunkSize, uids.count)
            let chunk = uids[start..<end]
            start = end
            let placeholders = Array(repeating: "(?,?)", count: chunk.count).joined(separator: ",")
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    DELETE FROM \(table)
                    WHERE model_identifier=? AND model_version=?
                      AND (volume_id, node_id) IN (VALUES \(placeholders));
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return nil }

            guard bindDescriptor(stmt, descriptor), bindUIDs(stmt, from: 3, chunk) else {
                sqlite3_finalize(stmt)
                return nil
            }
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE {
                totalChanges += Int(sqlite3_changes(db))
            }
            sqlite3_finalize(stmt)
            guard result == SQLITE_DONE else { return nil }
        }
        return totalChanges
    }

    private func countLocked(for descriptor: MLModelDescriptor) -> Int {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                SELECT count FROM ml_embedding_count
                WHERE model_identifier=? AND model_version=?
                  AND embedding_dimension=? AND embedding_precision=?;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard bindEpochRead(stmt, descriptor), sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func deleteInvalidRowsLocked(_ uids: Set<PhotoUID>, descriptor: MLModelDescriptor) {
        guard !uids.isEmpty else { return }
        var stmt: OpaquePointer?
        // The statement ends after the transaction; one that did not prepare finalizes as a no-op.
        defer { sqlite3_finalize(stmt) }
        _ = SQLiteTransaction.immediate(db) {
            guard
                sqlite3_prepare_v2(
                    db,
                    "DELETE FROM ml_embeddings WHERE model_identifier=? AND model_version=? AND volume_id=? AND node_id=?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return false }
            var deleted = false
            for uid in uids {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                guard bindDescriptor(stmt, descriptor), bindUID(stmt, 3, uid), sqlite3_step(stmt) == SQLITE_DONE else {
                    return false
                }
                deleted = deleted || sqlite3_changes(db) > 0
            }
            return !deleted || bumpGenerationLocked(for: descriptor)
        }
    }

    @discardableResult
    private func bumpGenerationLocked(for descriptor: MLModelDescriptor) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                INSERT INTO ml_epoch_state(model_identifier, model_version, generation)
                VALUES(?,?,1)
                ON CONFLICT(model_identifier, model_version) DO UPDATE SET generation=generation+1;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        return bindDescriptor(stmt, descriptor) && sqlite3_step(stmt) == SQLITE_DONE
    }

    // Each bind helper returns false when a bind fails. A failed bind leaves its parameter NULL, so the caller must not
    // step the statement and gives the answer of a failed statement.

    private func bindDescriptor(_ stmt: OpaquePointer?, _ descriptor: MLModelDescriptor) -> Bool {
        sqlite3_bind_int64(stmt, 2, Int64(descriptor.version))
        return SQLiteBinding.bindText(stmt, 1, descriptor.identifier)
    }

    private func bindEpochRead(_ stmt: OpaquePointer?, _ descriptor: MLModelDescriptor) -> Bool {
        sqlite3_bind_int64(stmt, 3, Int64(descriptor.embeddingDimension))
        return bindDescriptor(stmt, descriptor) && SQLiteBinding.bindText(stmt, 4, Self.precision.rawValue)
    }

    /// Binds the volume and node of `uid` to parameters `index` and `index + 1`.
    private func bindUID(_ stmt: OpaquePointer?, _ index: Int32, _ uid: PhotoUID) -> Bool {
        SQLiteBinding.bindText(stmt, index, uid.volumeID) && SQLiteBinding.bindText(stmt, index + 1, uid.nodeID)
    }

    /// Binds `uids` to consecutive parameter pairs from `index` on.
    private func bindUIDs(_ stmt: OpaquePointer?, from index: Int32, _ uids: ArraySlice<PhotoUID>) -> Bool {
        uids.enumerated().allSatisfy { offset, uid in bindUID(stmt, index + Int32(offset) * 2, uid) }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }
}
