import Foundation
import SQLite3

public enum TimelineOrderMetadataError: Error {
    case unavailable
    case readFailed
}

/// Derived account cache. Neither the timeline schema nor any operational store depends on this file.
/// One actor owns the connection. Reconciliation reads at most 150 rows at a time; enrichment streams a merge.
public final class TimelineOrderMetadataStore {
    public static let databaseFileName = "timeline-order-v1.sqlite"
    public static let pageSize = 150
    public static let synchronizationChunkSize = 1_000
    private var db: OpaquePointer?
    private let url: URL
    private let policy: LibraryDatabasePolicy
    private let transient = SQLiteStoreSchemaGate.transientDestructor
    private var synchronizedInventory: InventorySignature?
    private var needsPublication = true
    private var lastRecordChangedOrder = false
    private var synchronization: Synchronization?
    private var synchronizationGeneration: UInt64 = 0
    private var inventoryComplete = false

    private struct Synchronization {
        let generation: UInt64
        let signature: InventorySignature
        var offset = 0
        var sweepCursor: PhotoUID?
    }

    /// Process-local identity of UID/time membership. It keeps no inventory copy and ignores listing order.
    public struct InventorySignature: Equatable, Sendable {
        private let count: Int
        private let sum: UInt64
        private let xor: UInt64

        public init(_ items: [PhotoItem]) {
            var sum: UInt64 = 0
            var xor: UInt64 = 0
            for item in items {
                var hasher = Hasher()
                hasher.combine(item.uid)
                hasher.combine(item.captureTime.timeIntervalSince1970.bitPattern)
                let value = UInt64(bitPattern: Int64(hasher.finalize()))
                sum &+= value
                xor ^= value
            }
            self.count = items.count
            self.sum = sum
            self.xor = xor
        }
    }

    public struct Candidate: Sendable {
        public let uid: PhotoUID
        public let captureTime: Date
        public let needsOrder: Bool

        public init(uid: PhotoUID, captureTime: Date, needsOrder: Bool) {
            self.uid = uid
            self.captureTime = captureTime
            self.needsOrder = needsOrder
        }
    }

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
        self.url = url
        self.policy = policy
        func open() -> OpaquePointer? {
            SQLiteStoreSchemaGate.openRebuildableStore(
                at: url, schemaSQL: Self.schema, policy: policy,
                verifyVersion: { handle in
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
                        return false
                    }
                    defer { sqlite3_finalize(stmt) }
                    return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 1
                },
                stampVersion: { sqlite3_exec($0, "PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK })
        }
        db = open()
        if db == nil, SQLiteStoreSchemaGate.removeDatabaseFiles(at: url) { db = open() }
        guard db != nil else { return nil }
        var check: OpaquePointer?
        let valid =
            sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &check, nil) == SQLITE_OK
            && sqlite3_step(check) == SQLITE_ROW
            && sqlite3_column_text(check, 0).map { String(cString: $0) } == "ok"
        sqlite3_finalize(check)
        if !valid {
            close()
            guard SQLiteStoreSchemaGate.removeDatabaseFiles(at: url) else { return nil }
            db = open()
            guard db != nil else { return nil }
        }
    }

    deinit { close() }
    public func close() {
        sqlite3_close(db)
        db = nil
        synchronizedInventory = nil
        synchronization = nil
        synchronizationGeneration &+= 1
        inventoryComplete = false
        needsPublication = true
    }

    /// Only this derived cache is removed. An unavailable replacement leaves ordering disabled.
    @discardableResult
    public func rebuild() -> Bool {
        close()
        guard SQLiteStoreSchemaGate.removeDatabaseFiles(at: url) else { return false }
        let replacement = TimelineOrderMetadataStore(url: url, policy: policy)
        db = replacement?.db
        replacement?.db = nil
        PhotoDiagnostics.shared.increment("timeline.order.cacheRebuild")
        return db != nil
    }

    private static let schema = """
        CREATE TABLE photo_order(
          vol TEXT NOT NULL, node TEXT NOT NULL, t REAL NOT NULL, second REAL NOT NULL,
          exact REAL, identity TEXT, inspected INTEGER NOT NULL DEFAULT 0,
          published INTEGER NOT NULL DEFAULT 0, mime_seen INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(vol,node)
        );
        CREATE INDEX order_second ON photo_order(second);
        CREATE INDEX order_pending_second ON photo_order(second,inspected);
        CREATE INDEX order_timeline ON photo_order(t,vol,node);
        CREATE TABLE order_revision(value INTEGER NOT NULL);
        INSERT INTO order_revision VALUES(0);
        """

    /// Uses the existing inventory array. The temporary key table bounds heap use and sweeps vanished links.
    @discardableResult
    public func synchronize(_ items: [PhotoItem], classifiedUIDs: Set<PhotoUID>) -> Bool {
        synchronize(items, isClassified: classifiedUIDs.contains)
    }

    @discardableResult
    public func synchronize(_ items: [PhotoItem], isClassified: (PhotoUID) -> Bool) -> Bool {
        guard db != nil, !Task.isCancelled else { return false }
        let signature = InventorySignature(items)
        guard synchronizedInventory != signature else { return true }
        guard let generation = beginSynchronization(signature: signature) else { return false }
        defer { finishSynchronization(generation: generation) }
        while let complete = synchronizeChunk(items, isClassified: isClassified, generation: generation) {
            if complete { return true }
        }
        return false
    }

    /// Commits bounded writes and sweeps before each yield. The connection stays on its owning actor.
    /// A replacement pass invalidates the old scratch keys. Interrupted rows replay idempotently on restart.
    public func synchronizeInChunks(
        _ items: [PhotoItem], isClassified: (PhotoUID) -> Bool,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Bool {
        guard db != nil, !Task.isCancelled else { return false }
        let signature = InventorySignature(items)
        guard synchronizedInventory != signature else { return true }
        guard let generation = beginSynchronization(signature: signature) else { return false }
        defer { finishSynchronization(generation: generation) }
        while let complete = synchronizeChunk(items, isClassified: isClassified, generation: generation) {
            if complete { return true }
            await Task.yield()
        }
        return false
    }

    private func beginSynchronization(signature: InventorySignature) -> UInt64? {
        synchronizationGeneration &+= 1
        synchronization = nil
        synchronizedInventory = nil
        inventoryComplete = false
        let setup = """
            DROP TABLE IF EXISTS temp.incoming_order;
            CREATE TEMP TABLE incoming_order(vol TEXT,node TEXT,PRIMARY KEY(vol,node)) WITHOUT ROWID;
            """
        guard sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK else { return nil }
        synchronization = Synchronization(generation: synchronizationGeneration, signature: signature)
        PhotoDiagnostics.shared.increment("timeline.order.syncPass")
        return synchronizationGeneration
    }

    private func finishSynchronization(generation: UInt64) {
        if synchronization?.generation == generation { synchronization = nil }
    }

    /// nil means failure or retirement; true means the complete inventory and sweep committed.
    private func synchronizeChunk(
        _ items: [PhotoItem], isClassified: (PhotoUID) -> Bool, generation: UInt64
    ) -> Bool? {
        guard db != nil, !Task.isCancelled, var progress = synchronization,
            progress.generation == generation
        else { return nil }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return nil }
        let complete: Bool
        if progress.offset < items.count {
            let end = min(progress.offset + Self.synchronizationChunkSize, items.count)
            guard upsertSynchronizationChunk(items[progress.offset..<end], isClassified: isClassified) else {
                _ = rollback()
                return nil
            }
            progress.offset = end
            complete = false
        } else {
            let page: [PhotoUID]
            do { page = try synchronizationSweepPage(after: progress.sweepCursor) } catch {
                _ = rollback()
                return nil
            }
            if let last = page.last {
                guard sweepSynchronizationChunk(after: progress.sweepCursor, through: last) else {
                    _ = rollback()
                    return nil
                }
                progress.sweepCursor = last
                complete = false
            } else {
                complete = true
            }
        }
        guard !Task.isCancelled, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            _ = rollback()
            return nil
        }
        PhotoDiagnostics.shared.increment("timeline.order.syncChunk")
        synchronization = progress
        if complete {
            synchronizedInventory = progress.signature
            inventoryComplete = true
            needsPublication = true
        }
        return complete
    }

    private func upsertSynchronizationChunk(_ items: ArraySlice<PhotoItem>, isClassified: (PhotoUID) -> Bool) -> Bool {
        var incoming: OpaquePointer?
        var upsert: OpaquePointer?
        defer {
            sqlite3_finalize(incoming)
            sqlite3_finalize(upsert)
        }
        let sql = """
            INSERT INTO photo_order(vol,node,t,second,mime_seen) VALUES(?1,?2,?3,?4,?5)
            ON CONFLICT(vol,node) DO UPDATE SET t=excluded.t, second=excluded.second, mime_seen=excluded.mime_seen,
              exact=CASE WHEN photo_order.t=excluded.t THEN photo_order.exact END,
              identity=CASE WHEN photo_order.t=excluded.t THEN photo_order.identity END,
              inspected=CASE WHEN photo_order.t=excluded.t THEN photo_order.inspected ELSE 0 END,
              published=CASE WHEN photo_order.t=excluded.t THEN photo_order.published ELSE 0 END
            WHERE photo_order.t IS NOT excluded.t OR photo_order.mime_seen IS NOT excluded.mime_seen;
            """
        guard
            sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO incoming_order VALUES(?,?);", -1, &incoming, nil)
                == SQLITE_OK,
            sqlite3_prepare_v2(db, sql, -1, &upsert, nil) == SQLITE_OK
        else { return false }
        for item in items {
            if Task.isCancelled { return false }
            sqlite3_reset(incoming)
            bind(item.uid, to: incoming)
            guard sqlite3_step(incoming) == SQLITE_DONE else { return false }
            sqlite3_reset(upsert)
            bind(item.uid, to: upsert)
            let time = item.captureTime.timeIntervalSince1970
            sqlite3_bind_double(upsert, 3, time)
            sqlite3_bind_double(upsert, 4, floor(time))
            sqlite3_bind_int(upsert, 5, isClassified(item.uid) ? 1 : 0)
            guard sqlite3_step(upsert) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func synchronizationSweepPage(after cursor: PhotoUID?) throws -> [PhotoUID] {
        var stmt: OpaquePointer?
        let sql = "SELECT vol,node FROM photo_order WHERE (vol,node)>(?1,?2) ORDER BY vol,node LIMIT ?3;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TimelineOrderMetadataError.readFailed
        }
        defer { sqlite3_finalize(stmt) }
        bind(cursor ?? PhotoUID(volumeID: "", nodeID: ""), to: stmt)
        sqlite3_bind_int(stmt, 3, Int32(Self.synchronizationChunkSize))
        var result: [PhotoUID] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            guard let vol = string(stmt, 0), let node = string(stmt, 1) else {
                throw TimelineOrderMetadataError.readFailed
            }
            result.append(PhotoUID(volumeID: vol, nodeID: node))
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw TimelineOrderMetadataError.readFailed }
        return result
    }

    private func sweepSynchronizationChunk(after cursor: PhotoUID?, through end: PhotoUID) -> Bool {
        var stmt: OpaquePointer?
        let sql = """
            DELETE FROM photo_order WHERE (vol,node)>(?1,?2) AND (vol,node)<=(?3,?4)
              AND NOT EXISTS(SELECT 1 FROM incoming_order i WHERE i.vol=photo_order.vol AND i.node=photo_order.node);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(cursor ?? PhotoUID(volumeID: "", nodeID: ""), to: stmt)
        sqlite3_bind_text(stmt, 3, end.volumeID, -1, transient)
        sqlite3_bind_text(stmt, 4, end.nodeID, -1, transient)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private static let collision = """
        EXISTS(SELECT 1 FROM photo_order other WHERE other.second=o.second
          AND (other.vol!=o.vol OR other.node!=o.node))
        """
    private static let workSQL = """
        SELECT vol,node,t,(inspected=0 AND \(collision)) FROM photo_order o INDEXED BY sqlite_autoindex_photo_order_1
        WHERE (mime_seen=0 OR (inspected=0 AND \(collision)))
          AND (vol,node)>(?1,?2) ORDER BY vol,node LIMIT ?3;
        """

    /// The key frontier prevents a failed or omitted link from retrying repeatedly inside one pass.
    public func nextPage(after cursor: PhotoUID? = nil, limit: Int = pageSize) throws -> [Candidate] {
        guard db != nil else { throw TimelineOrderMetadataError.unavailable }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.workSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw TimelineOrderMetadataError.readFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, cursor?.volumeID ?? "", -1, transient)
        sqlite3_bind_text(stmt, 2, cursor?.nodeID ?? "", -1, transient)
        sqlite3_bind_int(stmt, 3, Int32(max(1, min(Self.pageSize, limit))))
        var rows: [Candidate] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            guard let vol = string(stmt, 0), let node = string(stmt, 1) else {
                throw TimelineOrderMetadataError.readFailed
            }
            rows.append(
                Candidate(
                    uid: PhotoUID(volumeID: vol, nodeID: node),
                    captureTime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    needsOrder: sqlite3_column_int(stmt, 3) != 0))
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw TimelineOrderMetadataError.readFailed }
        return rows
    }

    /// A nil exact time is an authenticated absent/unsupported value, not a decryption or transport failure.
    @discardableResult
    public func record(_ values: [PhotoUID: TimelineOrderMetadata], classifiedUIDs: Set<PhotoUID> = []) -> Bool {
        lastRecordChangedOrder = false
        guard db != nil else { return false }
        var lookup: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "SELECT inspected,mime_seen FROM photo_order WHERE vol=?1 AND node=?2;", -1, &lookup, nil)
                == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(lookup) }
        var needsWrite = false
        for uid in values.keys {
            sqlite3_reset(lookup)
            bind(uid, to: lookup)
            let step = sqlite3_step(lookup)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { return false }
            needsWrite = needsWrite || (step == SQLITE_ROW && sqlite3_column_int(lookup, 0) == 0)
        }
        for uid in classifiedUIDs {
            sqlite3_reset(lookup)
            bind(uid, to: lookup)
            let step = sqlite3_step(lookup)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { return false }
            needsWrite = needsWrite || (step == SQLITE_ROW && sqlite3_column_int(lookup, 1) == 0)
        }
        guard needsWrite else { return true }
        PhotoDiagnostics.shared.increment("timeline.order.recordWrite")
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "UPDATE photo_order SET exact=?3, identity=?4, inspected=1 WHERE vol=?1 AND node=?2 AND inspected=0;",
                -1, &stmt, nil) == SQLITE_OK
        else { return rollback() }
        defer { sqlite3_finalize(stmt) }
        var recordedOrder = false
        for (uid, metadata) in values {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bind(uid, to: stmt)
            if let exact = metadata.exactCaptureTime, exact.timeIntervalSince1970.isFinite {
                sqlite3_bind_double(stmt, 3, exact.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            if let identity = metadata.stableIdentity { sqlite3_bind_text(stmt, 4, identity, -1, transient) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { return rollback() }
            recordedOrder = recordedOrder || sqlite3_changes(db) > 0
        }
        var mime: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "UPDATE photo_order SET mime_seen=1 WHERE vol=?1 AND node=?2 AND mime_seen=0;", -1, &mime, nil)
                == SQLITE_OK
        else { return rollback() }
        defer { sqlite3_finalize(mime) }
        for uid in classifiedUIDs {
            sqlite3_reset(mime)
            bind(uid, to: mime)
            guard sqlite3_step(mime) == SQLITE_DONE else { return rollback() }
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else { return rollback() }
        lastRecordChangedOrder = recordedOrder
        needsPublication = needsPublication || recordedOrder
        return true
    }

    /// A detail read publishes only its own second. First inspections never scan the whole cache per photo.
    public func recordResolvedMetadata(
        for uid: PhotoUID, metadata: TimelineOrderMetadata?, isClassified: Bool
    ) -> Bool {
        let values: [PhotoUID: TimelineOrderMetadata] = metadata.map { [uid: $0] } ?? [:]
        guard record(values, classifiedUIDs: isClassified ? [uid] : []) else { return false }
        guard lastRecordChangedOrder else { return true }
        do {
            _ = try publishCompletedSeconds(containing: uid)
            return true
        } catch {
            return false
        }
    }

    /// Only completed seconds become visible. Published evidence stays available while a new member is inspected.
    public func publishCompletedSeconds() throws -> Bool {
        try publishCompletedSeconds(containing: nil)
    }

    private func publishCompletedSeconds(containing uid: PhotoUID?) throws -> Bool {
        guard db != nil else { throw TimelineOrderMetadataError.unavailable }
        guard inventoryComplete, needsPublication else { return false }
        PhotoDiagnostics.shared.increment(uid == nil ? "timeline.order.publishPass" : "timeline.order.publishSecond")
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            throw TimelineOrderMetadataError.unavailable
        }
        let scope = uid == nil ? "" : "AND second=(SELECT second FROM photo_order WHERE vol=?1 AND node=?2)"
        let sql = """
            UPDATE photo_order AS o SET published=1 WHERE inspected=1 AND published=0
              \(scope)
              AND NOT EXISTS(SELECT 1 FROM photo_order other WHERE other.second=o.second AND other.inspected=0);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            _ = rollback()
            throw TimelineOrderMetadataError.readFailed
        }
        defer { sqlite3_finalize(statement) }
        if let uid { bind(uid, to: statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            _ = rollback()
            throw TimelineOrderMetadataError.readFailed
        }
        let changed = sqlite3_changes(db) > 0
        if changed, sqlite3_exec(db, "UPDATE order_revision SET value=value+1;", nil, nil, nil) != SQLITE_OK {
            _ = rollback()
            throw TimelineOrderMetadataError.readFailed
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            _ = rollback()
            throw TimelineOrderMetadataError.readFailed
        }
        if uid == nil { needsPublication = false }
        return changed
    }

    public var revision: Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM order_revision;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// One indexed cache scan merges into the existing timeline. No full-library metadata dictionary is built.
    public func enrich(_ items: [PhotoItem]) -> [PhotoItem] {
        guard !items.isEmpty else { return items }
        var result = TimelineOrder.orderedByCaptureSecond(items, by: TimelineOrder.areInBaseOrder)
        var stmt: OpaquePointer?
        let sql =
            "SELECT vol,node,t,exact,identity FROM photo_order INDEXED BY order_timeline WHERE t>=?1 AND t<=?2 AND published=1 AND exact IS NOT NULL ORDER BY t,vol,node LIMIT ?3;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            rebuild()
            return items
        }
        // Execute with a zero limit to validate SQLite's schema without scanning a new cache.
        guard revision > 0 else {
            sqlite3_bind_int(stmt, 3, 0)
            let step = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard step == SQLITE_DONE else {
                rebuild()
                return items
            }
            return TimelineOrder.orderedByCaptureSecond(result, by: TimelineOrder.areInIncreasingOrder)
        }
        sqlite3_bind_int(stmt, 3, -1)
        var readFailed = false
        defer {
            sqlite3_finalize(stmt)
            if readFailed { rebuild() }
        }
        sqlite3_bind_double(stmt, 1, result[0].captureTime.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, result[result.count - 1].captureTime.timeIntervalSince1970)
        var index = 0
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            guard let vol = string(stmt, 0), let node = string(stmt, 1) else {
                readFailed = true
                return items
            }
            let uid = PhotoUID(volumeID: vol, nodeID: node)
            let base = PhotoItem(
                uid: uid, captureTime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)), mediaType: "")
            while index < result.count, TimelineOrder.areInBaseOrder(result[index], base) { index += 1 }
            if index < result.count, result[index].uid == uid {
                let metadata = TimelineOrderMetadata(
                    exactCaptureTime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    stableIdentity: string(stmt, 4))
                if let valid = metadata.validated(for: result[index].captureTime) {
                    result[index].timelineOrder = valid
                }
            }
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else {
            readFailed = true
            return items
        }
        return TimelineOrder.orderedByCaptureSecond(result, by: TimelineOrder.areInIncreasingOrder)
    }

    public func workQueryPlan() -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + Self.workSQL, -1, &stmt, nil) == SQLITE_OK else {
            return ""
        }
        defer { sqlite3_finalize(stmt) }
        var lines: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let line = string(stmt, 3) { lines.append(line) } }
        return lines.joined(separator: " | ")
    }

    private func bind(_ uid: PhotoUID, to stmt: OpaquePointer?) {
        sqlite3_bind_text(stmt, 1, uid.volumeID, -1, transient)
        sqlite3_bind_text(stmt, 2, uid.nodeID, -1, transient)
    }
    private func string(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }
    private func rollback() -> Bool {
        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        return false
    }
}
