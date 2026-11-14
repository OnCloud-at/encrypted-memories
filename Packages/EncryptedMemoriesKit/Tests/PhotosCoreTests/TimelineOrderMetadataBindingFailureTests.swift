import Foundation
import SQLiteTestSupport
import XCTest

@testable import PhotosCore

/// Every text bind of the timeline order cache checks its result (#1194). A failed bind leaves its parameter NULL: an
/// unchecked key bind made a page read look like the end of the work, a sweep or a record look done without touching
/// its row, and an unchecked stable identity stored NULL. Each test fails only the binds of the target statement: a value
/// longer than the lowered SQLITE_LIMIT_LENGTH fails with SQLITE_TOOBIG, as a bind that runs out of memory does. The
/// limit is 256, because the statements with a correlated subquery do not prepare under a lower one. With the check
/// the statement never steps, and the call gives the answer of a failed statement.
final class TimelineOrderMetadataBindingFailureTests: XCTestCase {
    private static let limit: Int32 = 256
    private static let long = PhotoUID(volumeID: "volume", nodeID: String(repeating: "n", count: 512))
    private static let short = PhotoUID(volumeID: "volume", nodeID: "node")

    private var directory: URL!
    private var store: TimelineOrderMetadataStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-order-binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let policy = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0)
        store = try XCTUnwrap(
            TimelineOrderMetadataStore(
                url: directory.appendingPathComponent(TimelineOrderMetadataStore.databaseFileName), policy: policy))
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func photo(_ uid: PhotoUID) -> PhotoItem {
        PhotoItem(uid: uid, captureTime: Date(timeIntervalSince1970: 500), mediaType: "image/jpeg")
    }

    /// Fails the binds of the first statement whose SQL contains `statement` that starts after the first statement whose
    /// SQL contains `earlier` finished, or at once without `earlier`.
    private func failBinds(of statement: String, after earlier: String? = nil) -> BindFailureUntilStep {
        let fault = BindFailureUntilStep(
            onDatabase: store.connectionForTesting, statement: statement, after: earlier, limit: Self.limit)
        if earlier == nil { XCTAssertEqual(fault.effectiveLimit, Self.limit, "The lowered length limit must apply") }
        return fault
    }

    private func assertFailedBeforeStep(
        _ fault: BindFailureUntilStep, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(fault.lowered, "The fault must reach the target statement", file: file, line: line)
        XCTAssertFalse(fault.stepped, "A value that does not bind must not reach the statement", file: file, line: line)
    }

    func testSynchronizeWithAKeyThatDoesNotBindFailsBeforeTheScratchInsert() {
        let fault = failBinds(of: "INSERT OR IGNORE INTO incoming_order", after: "CREATE TEMP TABLE incoming_order")
        defer { fault.remove() }
        XCTAssertFalse(
            store.synchronize([photo(Self.long)], classifiedUIDs: []),
            "INSERT OR IGNORE skips a scratch row without its key, so the sweep would remove the photo's row")
        assertFailedBeforeStep(fault)
    }

    func testSynchronizeWithAKeyThatDoesNotBindFailsBeforeTheOrderUpsert() {
        let fault = failBinds(of: "INSERT INTO photo_order", after: "INSERT OR IGNORE INTO incoming_order")
        defer { fault.remove() }
        XCTAssertFalse(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        assertFailedBeforeStep(fault)
    }

    /// The limit drops after the sweep page read: a lowered limit also fails a read of the long key.
    func testSweepWithAnEndKeyThatDoesNotBindFailsTheSynchronization() {
        let fault = failBinds(
            of: "DELETE FROM photo_order WHERE", after: "SELECT vol,node FROM photo_order WHERE (vol,node)>")
        defer { fault.remove() }
        XCTAssertFalse(
            store.synchronize([photo(Self.long)], classifiedUIDs: []), "A sweep that removed nothing is not complete")
        assertFailedBeforeStep(fault)
    }

    func testSweepPageWithACursorThatDoesNotBindFailsTheSynchronization() {
        let fault = failBinds(
            of: "SELECT vol,node FROM photo_order WHERE (vol,node)>", after: "DELETE FROM photo_order WHERE")
        defer { fault.remove() }
        XCTAssertFalse(
            store.synchronize([photo(Self.long)], classifiedUIDs: []),
            "A sweep page that does not bind is no proof that the sweep reached the end")
        assertFailedBeforeStep(fault)
    }

    func testNextPageWithACursorThatDoesNotBindIsAReadFailure() {
        XCTAssertTrue(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        let fault = failBinds(of: "SELECT vol,node,t,")
        defer { fault.remove() }
        XCTAssertThrowsError(try store.nextPage(after: Self.long), "A cursor that does not bind is no end of the work")
        assertFailedBeforeStep(fault)
    }

    func testRecordWithAKeyThatDoesNotBindFailsBeforeTheMetadataLookup() {
        XCTAssertTrue(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        let fault = failBinds(of: "SELECT inspected,mime_seen")
        defer { fault.remove() }
        XCTAssertFalse(
            store.record([Self.long: TimelineOrderMetadata(exactCaptureTime: Date(timeIntervalSince1970: 501))]),
            "A key that does not bind is no proof that the row needs no write")
        assertFailedBeforeStep(fault)
    }

    func testRecordWithAKeyThatDoesNotBindFailsBeforeTheClassificationLookup() {
        XCTAssertTrue(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        let fault = failBinds(of: "SELECT inspected,mime_seen")
        defer { fault.remove() }
        XCTAssertFalse(
            store.record([:], classifiedUIDs: [Self.long]),
            "A key that does not bind is no proof that the row needs no write")
        assertFailedBeforeStep(fault)
    }

    func testRecordWithAKeyThatDoesNotBindFailsBeforeTheMetadataUpdate() {
        XCTAssertTrue(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        let fault = failBinds(of: "UPDATE photo_order SET exact", after: "SELECT inspected,mime_seen")
        defer { fault.remove() }
        XCTAssertFalse(
            store.record([Self.long: TimelineOrderMetadata(exactCaptureTime: Date(timeIntervalSince1970: 501))]),
            "An update that matched no row recorded nothing")
        assertFailedBeforeStep(fault)
    }

    func testRecordWithAStableIdentityThatDoesNotBindFailsInsteadOfStoringNull() {
        XCTAssertTrue(store.synchronize([photo(Self.short)], classifiedUIDs: []))
        let fault = failBinds(of: "UPDATE photo_order SET exact", after: "SELECT inspected,mime_seen")
        defer { fault.remove() }
        XCTAssertFalse(
            store.record([Self.short: TimelineOrderMetadata(stableIdentity: String(repeating: "i", count: 512))]),
            "A stable identity that does not bind must not be stored as NULL")
        assertFailedBeforeStep(fault)
    }

    func testRecordWithAKeyThatDoesNotBindFailsBeforeTheClassificationUpdate() {
        XCTAssertTrue(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        let fault = failBinds(of: "UPDATE photo_order SET mime_seen", after: "SELECT inspected,mime_seen")
        defer { fault.remove() }
        XCTAssertFalse(store.record([:], classifiedUIDs: [Self.long]), "An update that matched no row recorded nothing")
        assertFailedBeforeStep(fault)
    }

    func testResolvedMetadataWithAKeyThatDoesNotBindFailsItsPublication() {
        XCTAssertTrue(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        let fault = failBinds(of: "UPDATE photo_order AS o SET published=1", after: "UPDATE photo_order SET exact")
        defer { fault.remove() }
        XCTAssertFalse(
            store.recordResolvedMetadata(
                for: Self.long, metadata: TimelineOrderMetadata(exactCaptureTime: Date(timeIntervalSince1970: 501)),
                isClassified: false),
            "A publication that matched no second published nothing")
        assertFailedBeforeStep(fault)
    }
}
