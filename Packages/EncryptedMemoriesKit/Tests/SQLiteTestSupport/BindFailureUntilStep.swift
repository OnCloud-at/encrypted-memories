import PhotosCore
import SQLite3

/// Fails only the binds of one statement: lowers SQLITE_LIMIT_LENGTH on a store's own database when it is created, or,
/// with `after`, when the first statement whose SQL contains `after` finishes. It restores the limit when the first
/// statement whose SQL contains `statement` starts to step, after its binds and before it builds a record. A bind of a
/// longer value fails as a bind that runs out of memory does, while the record of a statement that steps anyway is
/// written without the limit. Without that restore the record itself would exceed the limit and fail the step, which
/// hides an unchecked bind. SQLite raises a limit below 30 to 30; read `effectiveLimit` back.
public final class BindFailureUntilStep {
    private let database: () -> OpaquePointer?
    private let withLock: (() -> Void) -> Void
    private let statement: String
    private let earlier: String?
    private let limit: Int32
    public private(set) var lowered = false
    public private(set) var stepped = false

    /// Acts on the database of a store's `SQLiteStoreConnection`, under the connection's lock.
    public convenience init(
        on connection: SQLiteStoreConnection, statement: String, after earlier: String?, limit: Int32
    ) {
        self.init(
            database: { connection.database }, withLock: { body in connection.withLock(body) }, statement: statement,
            after: earlier, limit: limit)
    }

    /// Acts on the handle of a store that owns its database without `SQLiteStoreConnection`. Create and remove it while
    /// the store runs no operation.
    public convenience init(
        onDatabase handle: OpaquePointer?, statement: String, after earlier: String?, limit: Int32
    ) {
        self.init(
            database: { handle }, withLock: { body in body() }, statement: statement, after: earlier, limit: limit)
    }

    private init(
        database: @escaping () -> OpaquePointer?, withLock: @escaping (() -> Void) -> Void, statement: String,
        after earlier: String?, limit: Int32
    ) {
        self.database = database
        self.withLock = withLock
        self.statement = statement
        self.earlier = earlier
        self.limit = limit
        withLock {
            if earlier == nil {
                _ = sqlite3_limit(database(), SQLITE_LIMIT_LENGTH, limit)
                lowered = true
            }
            _ = sqlite3_trace_v2(
                database(), UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_PROFILE),
                { event, context, statement, _ in
                    guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                    let fault = Unmanaged<BindFailureUntilStep>.fromOpaque(context).takeUnretainedValue()
                    let text = String(cString: sql)
                    let db = sqlite3_db_handle(OpaquePointer(statement))
                    if event == UInt32(SQLITE_TRACE_PROFILE), !fault.lowered, let earlier = fault.earlier,
                        text.contains(earlier)
                    {
                        _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, fault.limit)
                        fault.lowered = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) == fault.limit
                    } else if event == UInt32(SQLITE_TRACE_STMT), fault.lowered, !fault.stepped,
                        text.contains(fault.statement)
                    {
                        _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_000_000_000)
                        fault.stepped = true
                    }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    public var effectiveLimit: Int32 {
        var effective: Int32 = 0
        withLock { effective = sqlite3_limit(database(), SQLITE_LIMIT_LENGTH, -1) }
        return effective
    }

    public func remove() {
        withLock {
            _ = sqlite3_trace_v2(database(), 0, nil, nil)
            _ = sqlite3_limit(database(), SQLITE_LIMIT_LENGTH, 1_000_000_000)
        }
    }
}

/// The SQLite handle of a store that keeps it in a stored property named `db`, read through reflection, so a test can
/// act on the store's own handle without a test hook in the store. Pass the store itself, not an Optional.
public func storeDatabase(_ store: Any) -> OpaquePointer? {
    Mirror(reflecting: store).children.first(where: { $0.label == "db" })?.value as? OpaquePointer
}
