import PhotosCore
import SQLite3

/// Fails every statement whose expanded SQL matches, until `stop()` or until it failed `failures` statements. Other
/// statements and probes run normally. With `fails: false` it only counts the matching statement runs. A failed
/// statement ends its first step with SQLITE_INTERRUPT, as a step that runs out of memory or meets a busy or failing
/// disk does.
public final class SQLiteStatementFaults {
    private let database: () -> OpaquePointer?
    private let withLock: (() -> Void) -> Void
    private let matches: (String) -> Bool
    private let fails: Bool
    private let failures: Int
    private var statement: UnsafeMutableRawPointer?
    private var fired = 0
    private var matched = 0
    private var stopped = false

    /// Acts on the database of a store's `SQLiteStoreConnection`, under the connection's lock.
    public convenience init(
        on connection: SQLiteStoreConnection, fails: Bool = true, failures: Int = .max,
        matches: @escaping (String) -> Bool
    ) {
        self.init(
            database: { connection.database }, withLock: { body in connection.withLock(body) }, fails: fails,
            failures: failures, matches: matches)
    }

    /// Acts on the handle of a store that owns its database without `SQLiteStoreConnection`. Create and stop it while
    /// the store runs no operation.
    public convenience init(
        onDatabase handle: OpaquePointer?, fails: Bool = true, failures: Int = .max,
        matches: @escaping (String) -> Bool
    ) {
        self.init(
            database: { handle }, withLock: { body in body() }, fails: fails, failures: failures, matches: matches)
    }

    private init(
        database: @escaping () -> OpaquePointer?, withLock: @escaping (() -> Void) -> Void, fails: Bool,
        failures: Int, matches: @escaping (String) -> Bool
    ) {
        self.database = database
        self.withLock = withLock
        self.matches = matches
        self.fails = fails
        self.failures = failures
        withLock {
            sqlite3_trace_v2(
                database(), UInt32(SQLITE_TRACE_STMT),
                { _, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let faults = Unmanaged<SQLiteStatementFaults>.fromOpaque(context).takeUnretainedValue()
                    faults.statement = nil
                    guard let expanded = sqlite3_expanded_sql(OpaquePointer(statement)) else { return 0 }
                    defer { sqlite3_free(expanded) }
                    guard faults.matches(String(cString: expanded)) else { return 0 }
                    faults.matched += 1
                    if faults.fails, faults.fired < faults.failures { faults.statement = statement }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
            sqlite3_progress_handler(
                database(), 1,
                { context in
                    guard let context else { return 0 }
                    let faults = Unmanaged<SQLiteStatementFaults>.fromOpaque(context).takeUnretainedValue()
                    guard faults.statement != nil else { return 0 }
                    faults.statement = nil
                    faults.fired += 1
                    return 1
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// The number of statements that this fault failed.
    public var firedCount: Int {
        var count = 0
        withLock { count = fired }
        return count
    }

    /// The number of statement runs whose expanded SQL matched.
    public var matchedCount: Int {
        var count = 0
        withLock { count = matched }
        return count
    }

    public func stop() {
        withLock {
            guard !stopped, database() != nil else { return }
            stopped = true
            sqlite3_trace_v2(database(), 0, nil, nil)
            sqlite3_progress_handler(database(), 0, nil, nil)
        }
    }
}
