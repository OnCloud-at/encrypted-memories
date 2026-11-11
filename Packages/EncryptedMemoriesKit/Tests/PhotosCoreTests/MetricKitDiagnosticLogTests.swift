import Foundation
import XCTest

@testable import PhotosCore

/// The bounded file of MetricKit summaries that lives across launches.
final class MetricKitDiagnosticLogTests: XCTestCase {
    private typealias Fixtures = MetricKitDiagnosticFixtures

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricKitDiagnosticLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("EncryptedMemories/metrickit-diagnostics-v1.json") }

    private func makeLog(
        entryLimit: Int = MetricKitDiagnosticLog.entryLimit, byteLimit: Int = MetricKitDiagnosticLog.byteLimit,
        isPurgePending: @escaping @Sendable () -> Bool = { false }
    ) -> MetricKitDiagnosticLog {
        MetricKitDiagnosticLog(
            fileURL: fileURL, entryLimit: entryLimit, byteLimit: byteLimit, isPurgePending: isPurgePending)
    }

    private func crash(_ index: Int) -> MetricKitDiagnosticInput {
        Fixtures.input(seconds: Double(index) * 3600, callStackTreeJSON: wideTree)
    }

    private var wideTree: Data {
        Fixtures.tree([(roots: [Fixtures.chain((0..<12).map { "VectorKitFramework\($0)" })], attributed: true)])
    }

    func testASummarySurvivesANewLaunch() {
        let input = Fixtures.input(callStackTreeJSON: wideTree)
        makeLog().record(input)

        let afterRelaunch = makeLog().supportSnapshot()

        XCTAssertEqual(afterRelaunch.entries, [MetricKitDiagnosticSummary.fields(for: input)])
        XCTAssertEqual(afterRelaunch.dropped, 0)
        XCTAssertEqual(afterRelaunch.entries.first?["kind"], "crash")
    }

    func testTheEntryLimitDropsTheOldestAndCountsThem() {
        let log = makeLog(entryLimit: 3)
        for index in 0..<5 { log.record(crash(index)) }

        let snapshot = log.supportSnapshot()

        XCTAssertEqual(
            snapshot.entries.map { $0["rangeStart"] },
            [2, 3, 4].map { MetricKitDiagnosticSummary.fields(for: crash($0))["rangeStart"] },
            "the three newest entries remain, oldest first")
        XCTAssertEqual(snapshot.dropped, 2)
    }

    func testTheByteLimitDropsTheOldestEntries() throws {
        let one = try JSONEncoder().encode([MetricKitDiagnosticSummary.fields(for: crash(0))]).count
        let byteLimit = one * 3 + 8
        let log = makeLog(entryLimit: 100, byteLimit: byteLimit)
        for index in 0..<10 { log.record(crash(index)) }

        let snapshot = log.supportSnapshot()

        XCTAssertGreaterThan(snapshot.entries.count, 0)
        XCTAssertLessThan(snapshot.entries.count, 10)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(snapshot.entries).count, byteLimit)
        XCTAssertEqual(snapshot.dropped, 10 - snapshot.entries.count)
        XCTAssertEqual(
            snapshot.entries.last?["rangeStart"], MetricKitDiagnosticSummary.fields(for: crash(9))["rangeStart"])
    }

    func testTheDefaultBoundsHoldTwentyLargeEntriesInTwentyFourKilobytes() throws {
        XCTAssertEqual(MetricKitDiagnosticLog.entryLimit, 20)
        XCTAssertEqual(MetricKitDiagnosticLog.byteLimit, 24_576)
        let log = makeLog()
        for index in 0..<25 { log.record(crash(index)) }

        let snapshot = log.supportSnapshot()

        XCTAssertEqual(snapshot.entries.count, 20)
        XCTAssertEqual(snapshot.dropped, 5)
        XCTAssertLessThanOrEqual(try Data(contentsOf: fileURL).count, MetricKitDiagnosticLog.byteLimit + 256)
    }

    func testTheSameDiagnosticTwiceIsKeptOnce() {
        let log = makeLog()
        log.record(crash(0))
        log.record(crash(0))

        XCTAssertEqual(log.supportSnapshot().entries.count, 1)
        XCTAssertEqual(log.supportSnapshot().dropped, 0)
    }

    func testWhileASignOutPurgeIsPendingNothingIsWritten() {
        makeLog(isPurgePending: { true }).record(crash(0))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(makeLog().supportSnapshot(), MetricKitDiagnosticSupportSnapshot())
    }

    func testALogWithoutAFileRecordsNothing() {
        let log = MetricKitDiagnosticLog(fileURL: nil)
        log.record(crash(0))

        XCTAssertEqual(log.supportSnapshot(), MetricKitDiagnosticSupportSnapshot())
    }

    func testAStoredKeyOutsideTheAllowlistNeverReachesTheExport() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = #"""
            {"dropped":1,"entries":[
              {"kind":"crash","signal":"11","path":"/private/var/x","photoName":"Holiday.jpg"},
              {"path":"/private/var/y"}]}
            """#
        try Data(stored.utf8).write(to: fileURL)

        let snapshot = makeLog().supportSnapshot()

        XCTAssertEqual(snapshot.entries, [["kind": "crash", "signal": "11"]])
        XCTAssertEqual(snapshot.dropped, 1)
    }

    func testADamagedFileIsReplacedByTheNextRecord() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: fileURL)
        let log = makeLog()
        XCTAssertEqual(log.supportSnapshot(), MetricKitDiagnosticSupportSnapshot())

        log.record(crash(0))

        XCTAssertEqual(log.supportSnapshot().entries.count, 1)
    }

    func testAFileThatCannotBeReadIsNotOverwritten() throws {
        let log = makeLog()
        log.record(crash(0))
        let before = try Data(contentsOf: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)

        log.record(crash(1))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testRecordsFromManyThreadsKeepTheBoundExactly() {
        let log = makeLog(entryLimit: 20)
        let inputs = (0..<50).map { crash($0) }
        DispatchQueue.concurrentPerform(iterations: inputs.count) { log.record(inputs[$0]) }

        let snapshot = log.supportSnapshot()

        XCTAssertEqual(snapshot.entries.count, 20)
        XCTAssertEqual(snapshot.dropped, 30)
    }
}
