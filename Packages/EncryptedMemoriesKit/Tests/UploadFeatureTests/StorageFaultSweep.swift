import Foundation
import PhotosCore
import SQLite3
import XCTest

// Fault-injection sweep for storage-changing operations (#1141).
//
// A storage-changing operation is registered once, as a `StorageFaultCase` in `storageFaultCases`. The sweep then runs
// it on real store files and fails each SQLite statement of its fault targets in turn. The terms below have one
// meaning:
//
// - Statement: one SQLite statement that starts on the connection of a fault target (SQLITE_TRACE_STMT), including
//   BEGIN, COMMIT, ROLLBACK, PRAGMA and reads. A fault target is a store of the world; a cross-store operation lists
//   every store it writes, so that a crash between the writes of two stores is a point too.
// - Point k: the k-th statement of the fault-free reference run, counted across all fault targets in the order they
//   start. The sweep visits every point once.
// - Failure at point k: statement k fails with SQLITE_INTERRUPT. The operation's own error handling then runs.
// - Crash image at point k: a copy of every file of the world, except the `-shm` index, taken just before statement k
//   runs. It models a process kill at that moment (iOS ends the app), not a power loss. The image keeps its WAL
//   unrecovered: the restart's own stores open it first, as after a real kill, so a store that cannot open a WAL that
//   a killed process left behind fails rule I4.
// - Restart: new store objects open the files, as a launch does, and run the operation once more without a fault. A
//   store that does not open at a restart fails rule I4.
// - Inspection: the sweep reads a state only from a copy of the files, never from the files that a restart opens.
// - Records: the durable keys that the case declares, such as a photo's catalog row or its queue entry.
// - State: every row of every table of the world's stores, compared for equality. A text column that holds JSON
//   compares by content, because `JSONEncoder` writes keys in no fixed order.
//
// After every point the sweep checks these fixed rules. A case chooses only its atomicity.
//
// - I1 No loss: every record that exists before the operation and after the fault-free run exists after the failure
//   and in the crash image. A record that only the successful run removes may disappear. After a restart, I4 already
//   requires the complete state of the fault-free run.
// - I2 No half-written state (`.allOrNothing` only): when the operation reports a failure, the state equals the state
//   before it. A crash image equals the state before or the state after the fault-free run.
// - I3 No duplicate upload: the fake remote records each upload key at most once, across the failed run and the
//   restart. The remote lives outside the device, so a crash keeps its record.
// - I4 Restart converges: a restart from the failed state and from the crash image reports success and reaches
//   exactly the state of the fault-free run.
// - I5 Honest outcome: when the operation reports success despite the failure, its state equals the state of the
//   fault-free run.
//
// The sweep is deterministic: every point starts from a copy of one seed, the cases use fixed clocks, and nothing
// waits for wall-clock time. The sweep also checks that each fault hits the statement that its point names (the SQL
// text before binding, on the same target): a run that ends before point k reports `faultDidNotFire`, and a run whose
// k-th statement differs reports `faultHitAnotherStatement`. The check compares the SQL text before binding: an
// order change between statements with different SQL text fails the sweep; statements with identical text, such as
// two inserts of one prepared statement with different values, are not told apart.
//
// Never faulted, so outside these rules: statements of `seed`, `open` (schema gate, start-up replays) and `close`;
// statements of the error path after the failed statement (ROLLBACK, compensating writes such as
// `clearFullScanResumePoint`); a second fault in the same run; any failure other than SQLITE_INTERRUPT, such as a full
// disk or a busy database; faults in the SQLite VFS (page write, sync, truncate); file writes outside SQLite until
// #1149 adds their fault point; and power loss, where an unsynced write is lost.

enum StorageFaultAtomicity: Sendable {
    /// One transaction: a failure leaves the state before the operation.
    case allOrNothing
    /// Several transactions: a failure can leave an intermediate state, which a restart must complete.
    case convergesAfterRestart
}

enum StorageFaultRule: String, Sendable {
    case noLoss = "I1 no loss"
    case allOrNothing = "I2 no half-written state"
    case noDuplicateUpload = "I3 no duplicate upload"
    case restartConverges = "I4 restart converges"
    case honestOutcome = "I5 honest outcome"
    case faultDidNotFire = "the injected fault did not fire"
    case faultHitAnotherStatement = "the injected fault hit another statement"
}

/// Where in a point the sweep checks a rule.
enum StorageFaultPhase: String, Sendable {
    case failedRun = "after the failed statement"
    case crashImage = "in the crash image"
    case restartAfterFailure = "at the restart after the failed statement"
    case restartFromCrashImage = "at the restart from the crash image"
}

struct StorageFaultViolation: CustomStringConvertible {
    let rule: StorageFaultRule
    let phase: StorageFaultPhase
    let point: Int
    let statement: String
    let detail: String

    var description: String {
        "\(rule.rawValue) \(phase.rawValue), statement \(point) (\(statement.prefix(120))): \(detail)"
    }
}

struct StorageFaultSweepReport {
    var statements: [String] = []
    var violations: [StorageFaultViolation] = []
    var seconds: Double = 0
    /// Each violated rule with the phase that found it, as "rule, phase".
    var violatedChecks: Set<String> { Set(violations.map { "\($0.rule.rawValue), \($0.phase.rawValue)" }) }
}

/// The full content of a world and its records.
struct StorageFaultState: Equatable {
    /// Every row of every table, by "file/table", sorted.
    var tables: [String: [String]] = [:]
    /// The keys that rule I1 protects, by record kind.
    var records: [String: Set<String>] = [:]

    /// Adds every table of the SQLite file at `url`, every row as text with its SQLite type. The file must not be open
    /// in a store. This is the shared table dump of the test target.
    mutating func addSQLiteTables(of url: URL) throws {
        try withSQLiteDatabase(at: url) { database in
            let names = "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name;"
            for table in try sqliteRows(database, names, typed: false) {
                tables["\(url.lastPathComponent)/\(table)"] = try sqliteRows(
                    database, "SELECT * FROM \"\(table)\";"
                ).sorted()
            }
        }
    }

    /// Adds the keys that `sql` returns from the SQLite file at `url` as records of `kind`.
    mutating func addRecords(_ kind: String, of url: URL, sql: String) throws {
        try withSQLiteDatabase(at: url) { records[kind] = Set(try sqliteRows($0, sql)) }
    }
}

/// The upload record of the fake remote. The remote lives outside the device, so a restart or a crash keeps it.
final class StorageFaultRemote: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String]

    init(uploads: [String] = []) { recorded = uploads }

    var uploads: [String] { lock.withLock { recorded } }
    func recordUpload(_ key: String) { lock.withLock { recorded.append(key) } }
    func copy() -> StorageFaultRemote { StorageFaultRemote(uploads: uploads) }
}

/// One storage-changing operation of the core, run through its production entry point on real store files.
protocol StorageFaultCase: Sendable {
    associatedtype World
    /// Stable name, such as "catalog.upsertBatch".
    var id: String { get }
    var atomicity: StorageFaultAtomicity { get }
    /// Writes the state before the operation into `directory` and closes every store. Runs once per sweep.
    func seed(in directory: URL, remote: StorageFaultRemote) async throws
    /// Opens new store objects on the files in `directory`, as a launch does, with its start-up replays.
    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World
    /// Every store of the world that the operation writes. Each has a `connection: SQLiteStoreConnection`.
    func faultTargets(of world: World) -> [Any]
    /// The operation. True when it reports success.
    func run(_ world: World) async -> Bool
    func close(_ world: World)
    /// The state and records of the files in `directory`. The sweep passes a copy that no store has open.
    func state(in directory: URL) throws -> StorageFaultState
}

enum StorageFaultSweep {
    /// Runs `faultCase` once without a fault, then once per statement with that statement failing.
    static func run<Case: StorageFaultCase>(_ faultCase: Case) async throws -> StorageFaultSweepReport {
        let started = Date()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-fault-sweep-\(faultCase.id)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        let seedRemote = StorageFaultRemote()
        try await faultCase.seed(in: seed, remote: seedRemote)
        let inspection = Inspection(root: root.appendingPathComponent("inspection", isDirectory: true))
        let before = try inspection.state(of: faultCase, in: seed)

        // The fault-free reference run names every statement and the state after a successful operation. Its recorder
        // counts statements like the fault does and never fires.
        let reference = try copy(seed, to: root.appendingPathComponent("reference", isDirectory: true))
        let statements = StatementLog()
        let world = try faultCase.open(reference, remote: seedRemote.copy())
        let recorders = try faultCase.faultTargets(of: world).enumerated().map { target, store in
            try SQLiteReadInterrupt(
                in: store,
                matches: {
                    statements.append(target: target, sql: $0)
                    return true
                }, occurrence: .max)
        }
        let referenceSucceeded = await faultCase.run(world)
        recorders.forEach { $0.stop() }
        faultCase.close(world)
        guard referenceSucceeded else { throw StorageFaultSweepError("\(faultCase.id) fails without a fault") }
        var check = StorageFaultCheck(
            atomicity: faultCase.atomicity, before: before, after: try inspection.state(of: faultCase, in: reference),
            inspection: inspection)

        let points = statements.all
        for (index, point) in points.enumerated() {
            check.point = (index + 1, point.sql)
            // The fault fails the n-th statement on the connection of the point's own target.
            let occurrence = points[..<index].filter { $0.target == point.target }.count + 1
            let pointDirectory = root.appendingPathComponent("point-\(index + 1)", isDirectory: true)
            let failed = try copy(seed, to: pointDirectory.appendingPathComponent("failed", isDirectory: true))
            let image = pointDirectory.appendingPathComponent("crash-image", isDirectory: true)
            let remote = seedRemote.copy()
            let crash = CrashCapture()
            let world = try faultCase.open(failed, remote: remote)
            let started = StatementLog()
            let fault = try SQLiteReadInterrupt(
                in: faultCase.faultTargets(of: world)[point.target],
                matches: {
                    started.append(target: point.target, sql: $0)
                    return true
                }, occurrence: occurrence,
                onFire: {
                    // The kill happens before the statement writes; a later restart opens this copy.
                    do {
                        try copy(failed, to: image)
                        crash.remote = remote.copy()
                    } catch {
                        crash.error = error
                    }
                })
            let reportedSuccess = await faultCase.run(world)
            fault.stop()
            faultCase.close(world)
            if let error = crash.error { throw error }
            guard let crashRemote = crash.remote else {
                check.report(.faultDidNotFire, .failedRun, "the run ended before this statement")
                try? FileManager.default.removeItem(at: pointDirectory)
                continue
            }
            let hit = started.all[occurrence - 1].sql
            if hit != point.sql {
                check.report(.faultHitAnotherStatement, .failedRun, "the fault hit \(hit.prefix(120))")
            }
            let failedState = try inspection.state(of: faultCase, in: failed)
            check.noLoss(in: failedState, .failedRun)
            check.outcome(failedState, reportedSuccess: reportedSuccess)
            try await check.restart(faultCase, in: failed, remote: remote, .restartAfterFailure)

            let imageState = try inspection.state(of: faultCase, in: image)
            check.noLoss(in: imageState, .crashImage)
            check.crashImage(imageState)
            try await check.restart(faultCase, in: image, remote: crashRemote, .restartFromCrashImage)
            try? FileManager.default.removeItem(at: pointDirectory)
        }
        return StorageFaultSweepReport(
            statements: points.map(\.sql), violations: check.violations, seconds: Date().timeIntervalSince(started))
    }

    /// Copies every file of `source` except the SQLite `-shm` index, which SQLite rebuilds when a file opens.
    @discardableResult
    fileprivate static func copy(_ source: URL, to destination: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) where !name.hasSuffix("-shm") {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        }
        return destination
    }
}

/// The fixed rules, checked against the states before and after the fault-free run.
private struct StorageFaultCheck {
    let atomicity: StorageFaultAtomicity
    let before: StorageFaultState
    let after: StorageFaultState
    let inspection: Inspection
    var point = (0, "")
    private(set) var violations: [StorageFaultViolation] = []

    init(
        atomicity: StorageFaultAtomicity, before: StorageFaultState, after: StorageFaultState, inspection: Inspection
    ) {
        self.atomicity = atomicity
        self.before = before
        self.after = after
        self.inspection = inspection
    }

    mutating func report(_ rule: StorageFaultRule, _ phase: StorageFaultPhase, _ detail: String) {
        violations.append(
            StorageFaultViolation(rule: rule, phase: phase, point: point.0, statement: point.1, detail: detail))
    }

    /// I1: a record of the state before that the fault-free run keeps must exist in `state`. A restart needs no
    /// separate check: I4 requires its state to equal the state after the fault-free run, records included.
    mutating func noLoss(in state: StorageFaultState, _ phase: StorageFaultPhase) {
        for (kind, keys) in before.records.sorted(by: { $0.key < $1.key }) {
            let lost = keys.intersection(after.records[kind] ?? []).subtracting(state.records[kind] ?? [])
            if !lost.isEmpty { report(.noLoss, phase, "\(kind) \(lost.sorted()) is missing") }
        }
    }

    /// I2 and I5 for the state that the operation leaves after its failed statement.
    mutating func outcome(_ state: StorageFaultState, reportedSuccess: Bool) {
        if reportedSuccess {
            if state.tables != after.tables {
                report(.honestOutcome, .failedRun, "reported success, " + difference(state, after))
            }
        } else if atomicity == .allOrNothing, state.tables != before.tables {
            report(.allOrNothing, .failedRun, "reported failure, " + difference(state, before))
        }
    }

    /// I2 for a crash image: it holds the state before or the state after the operation, nothing between.
    mutating func crashImage(_ state: StorageFaultState) {
        guard atomicity == .allOrNothing, state.tables != before.tables, state.tables != after.tables else { return }
        report(.allOrNothing, .crashImage, difference(state, before))
    }

    /// I3 and I4 for a restart from the files in `directory`, with the remote as the failed run or the crash left it.
    mutating func restart<Case: StorageFaultCase>(
        _ faultCase: Case, in directory: URL, remote: StorageFaultRemote, _ phase: StorageFaultPhase
    ) async throws {
        let world: Case.World
        do {
            world = try faultCase.open(directory, remote: remote)
        } catch {
            return report(.restartConverges, phase, "the stores do not open: \(error)")
        }
        let succeeded = await faultCase.run(world)
        faultCase.close(world)
        let state = try inspection.state(of: faultCase, in: directory)
        if !succeeded { report(.restartConverges, phase, "reported failure") }
        if state.tables != after.tables { report(.restartConverges, phase, difference(state, after)) }
        let repeated = Dictionary(grouping: remote.uploads, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        if !repeated.isEmpty { report(.noDuplicateUpload, phase, "\(repeated) uploaded more than once") }
    }

    /// The first table whose rows differ.
    private func difference(_ state: StorageFaultState, _ expected: StorageFaultState) -> String {
        for table in Set(state.tables.keys).union(expected.tables.keys).sorted()
        where state.tables[table] != expected.tables[table] {
            return "\(table) is \(state.tables[table] ?? []) instead of \(expected.tables[table] ?? [])"
        }
        return "the tables differ"
    }
}

/// The statements of the reference run in the order they start, each with the index of its fault target.
private final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [(target: Int, sql: String)] = []
    var all: [(target: Int, sql: String)] { lock.withLock { statements } }
    func append(target: Int, sql: String) { lock.withLock { statements.append((target, sql)) } }
}

/// A small key-value SQLite store with the connection type of the production stores, so the sweep injects into it the
/// same way. The probe operations use it, and a case uses it to model a store whose production type it does not run.
final class StorageFaultTable {
    let connection: SQLiteStoreConnection

    init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let database = handle else {
            sqlite3_close(handle)
            throw StorageFaultSweepError("\(url.lastPathComponent) does not open")
        }
        connection = SQLiteStoreConnection(database: database)
        guard
            execute(
                "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS item(key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        else { throw StorageFaultSweepError("\(url.lastPathComponent) has no schema") }
    }

    /// Runs `sql`; a failure inside a transaction rolls it back.
    @discardableResult
    func execute(_ sql: String) -> Bool {
        connection.withLock {
            guard let database = connection.database else { return false }
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                if sqlite3_get_autocommit(database) == 0 { sqlite3_exec(database, "ROLLBACK;", nil, nil, nil) }
                return false
            }
            return true
        }
    }

    /// Adds the row `key` unless it exists. True when it added the row, false when the row existed, nil on failure.
    func insertIfAbsent(_ key: String, value: String = "") -> Bool? {
        connection.withLock {
            guard let database = connection.database else { return nil }
            var statement: OpaquePointer?
            guard
                sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO item VALUES(?,?);", -1, &statement, nil)
                    == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(statement) }
            do {
                try connection.bindText(statement, 1, key)
                try connection.bindText(statement, 2, value)
            } catch {
                return nil
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
            return sqlite3_changes(database) > 0
        }
    }

    func close() { connection.close() }
}

/// Reads states only from copies, so the files that a restart opens stay exactly as the run or the crash left them.
private struct Inspection {
    let root: URL

    func state<Case: StorageFaultCase>(of faultCase: Case, in directory: URL) throws -> StorageFaultState {
        let copy = try StorageFaultSweep.copy(directory, to: root.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: copy) }
        return try faultCase.state(in: copy)
    }
}

/// What the fault saves when it fires: the remote at the moment of the crash, or the error of the image copy.
private final class CrashCapture: @unchecked Sendable {
    var remote: StorageFaultRemote?
    var error: (any Error)?
}

/// Opens the SQLite file at `url` on its own connection with `flags` for `body`. The raw-file helper of this test
/// target; the sweep reads every state through it.
func withSQLiteDatabase<Result>(
    at url: URL, flags: Int32 = SQLITE_OPEN_READWRITE, _ body: (OpaquePointer) throws -> Result
) throws -> Result {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let database = handle else {
        sqlite3_close(handle)
        throw StorageFaultSweepError("\(url.lastPathComponent) does not open")
    }
    defer { sqlite3_close(database) }
    return try body(database)
}

/// A text that holds a JSON object or array, written with sorted keys. `JSONEncoder` writes keys in no fixed order, so
/// two writes of the same value can differ in bytes; the stores read such a column only by decoding it.
private func canonicalJSON(_ text: String) -> String {
    guard text.first == "{" || text.first == "[",
        let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
        let sorted = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    else { return text }
    return String(decoding: sorted, as: UTF8.self)
}

/// Every row of `sql`, each as its columns joined with " | ", each column as "type:value", or as its text alone when
/// `typed` is false. JSON text compares by content (`canonicalJSON`).
private func sqliteRows(_ database: OpaquePointer, _ sql: String, typed: Bool = true) throws -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw StorageFaultSweepError("\(sql) does not prepare: \(String(cString: sqlite3_errmsg(database)))")
    }
    defer { sqlite3_finalize(statement) }
    var rows: [String] = []
    var step = sqlite3_step(statement)
    while step == SQLITE_ROW {
        let columns = (0..<sqlite3_column_count(statement)).map { index -> String in
            guard typed else { return sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "null" }
            switch sqlite3_column_type(statement, index) {
            case SQLITE_NULL: return "null"
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, index))
                let bytes = sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: count) } ?? Data()
                return "blob:" + bytes.map { String(format: "%02x", $0) }.joined()
            case SQLITE_INTEGER: return "integer:" + String(cString: sqlite3_column_text(statement, index))
            case SQLITE_FLOAT: return "real:" + String(cString: sqlite3_column_text(statement, index))
            default: return "text:" + canonicalJSON(String(cString: sqlite3_column_text(statement, index)))
            }
        }
        rows.append(columns.joined(separator: " | "))
        step = sqlite3_step(statement)
    }
    guard step == SQLITE_DONE else {
        throw StorageFaultSweepError("\(sql) does not finish: \(String(cString: sqlite3_errmsg(database)))")
    }
    return rows
}

struct StorageFaultSweepError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
