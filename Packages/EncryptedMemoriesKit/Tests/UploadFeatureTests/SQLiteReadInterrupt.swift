import PhotosCore
import SQLite3
import XCTest

/// Interrupts one matching statement on the store's own connection. Later probes can succeed immediately.
final class SQLiteReadInterrupt {
    private let connection: SQLiteStoreConnection
    private let matching: String
    private let afterRows: Int
    private var remaining: Int
    private var statement: UnsafeMutableRawPointer?
    private var armed = false
    private var interrupted = false
    private(set) var fired = false
    private(set) var tracedRows = 0
    /// Runs once on the store's thread while the interrupted statement executes, before it fails.
    private let onFire: (() -> Void)?

    init(
        in store: Any, matching: String, occurrence: Int = 1, afterRows: Int = 0, onFire: (() -> Void)? = nil
    ) throws {
        connection = try XCTUnwrap(
            Mirror(reflecting: store).children.first(where: { $0.label == "connection" })?.value
                as? SQLiteStoreConnection)
        self.matching = matching
        self.afterRows = afterRows
        self.onFire = onFire
        remaining = occurrence
        connection.withLock {
            sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_ROW),
                { event, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let fault = Unmanaged<SQLiteReadInterrupt>.fromOpaque(context).takeUnretainedValue()
                    if event == UInt32(SQLITE_TRACE_ROW) {
                        guard !fault.fired, fault.statement == statement else { return 0 }
                        fault.tracedRows += 1
                        if fault.tracedRows >= fault.afterRows { fault.armed = true }
                        return 0
                    }
                    guard !fault.fired else { return 0 }
                    fault.statement = nil
                    fault.armed = false
                    guard let sql = sqlite3_sql(OpaquePointer(statement)),
                        String(cString: sql).contains(fault.matching)
                    else { return 0 }
                    fault.remaining -= 1
                    guard fault.remaining == 0 else { return 0 }
                    fault.statement = statement
                    if fault.afterRows == 0 { fault.armed = true }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
            sqlite3_progress_handler(
                connection.database, 1,
                { context in
                    guard let context else { return 0 }
                    let fault = Unmanaged<SQLiteReadInterrupt>.fromOpaque(context).takeUnretainedValue()
                    guard fault.armed, !fault.interrupted else { return 0 }
                    fault.fired = true
                    fault.interrupted = true
                    fault.onFire?()
                    return 1
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func stop() {
        connection.withLock {
            sqlite3_trace_v2(connection.database, 0, nil, nil)
            sqlite3_progress_handler(connection.database, 0, nil, nil)
        }
    }
}
