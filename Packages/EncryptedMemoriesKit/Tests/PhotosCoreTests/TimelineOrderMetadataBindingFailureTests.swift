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

    func testSynchronizeWithAKeyThatDoesNotBindFailsBeforeTheScratchInsert() throws {
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "INSERT OR IGNORE INTO incoming_order",
                after: "CREATE TEMP TABLE incoming_order", limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(
            store.synchronize([photo(Self.long)], classifiedUIDs: []),
            "INSERT OR IGNORE skips a scratch row without its key, so the sweep would remove the photo's row")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testSynchronizeWithAKeyThatDoesNotBindFailsBeforeTheOrderUpsert() throws {
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "INSERT INTO photo_order", after: "INSERT OR IGNORE INTO incoming_order",
                limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    /// The limit drops after the sweep page read: a lowered limit also fails a read of the long key.
    func testSweepWithAnEndKeyThatDoesNotBindFailsTheSynchronization() throws {
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "DELETE FROM photo_order WHERE",
                after: "SELECT vol,node FROM photo_order WHERE (vol,node)>", limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(
            store.synchronize([photo(Self.long)], classifiedUIDs: []), "A sweep that removed nothing is not complete")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testSweepPageWithACursorThatDoesNotBindFailsTheSynchronization() throws {
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "SELECT vol,node FROM photo_order WHERE (vol,node)>",
                after: "DELETE FROM photo_order WHERE", limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(
            store.synchronize([photo(Self.long)], classifiedUIDs: []),
            "A sweep page that does not bind is no proof that the sweep reached the end")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testNextPageWithACursorThatDoesNotBindIsAReadFailure() throws {
        XCTAssertTrue(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        let fault = try XCTUnwrap(
            BindFailureUntilStep(onStore: store!, statement: "SELECT vol,node,t,", after: nil, limit: Self.limit))
        defer { fault.remove() }
        XCTAssertThrowsError(try store.nextPage(after: Self.long), "A cursor that does not bind is no end of the work")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testRecordWithAKeyThatDoesNotBindFailsBeforeTheMetadataLookup() throws {
        XCTAssertTrue(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "SELECT inspected,mime_seen", after: nil, limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(
            store.record([Self.long: TimelineOrderMetadata(exactCaptureTime: Date(timeIntervalSince1970: 501))]),
            "A key that does not bind is no proof that the row needs no write")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testRecordWithAKeyThatDoesNotBindFailsBeforeTheClassificationLookup() throws {
        XCTAssertTrue(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "SELECT inspected,mime_seen", after: nil, limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(
            store.record([:], classifiedUIDs: [Self.long]),
            "A key that does not bind is no proof that the row needs no write")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testRecordWithAKeyThatDoesNotBindFailsBeforeTheMetadataUpdate() throws {
        XCTAssertTrue(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "UPDATE photo_order SET exact", after: "SELECT inspected,mime_seen",
                limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(
            store.record([Self.long: TimelineOrderMetadata(exactCaptureTime: Date(timeIntervalSince1970: 501))]),
            "An update that matched no row recorded nothing")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testRecordWithAStableIdentityThatDoesNotBindFailsInsteadOfStoringNull() throws {
        XCTAssertTrue(store.synchronize([photo(Self.short)], classifiedUIDs: []))
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "UPDATE photo_order SET exact", after: "SELECT inspected,mime_seen",
                limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(
            store.record([Self.short: TimelineOrderMetadata(stableIdentity: String(repeating: "i", count: 512))]),
            "A stable identity that does not bind must not be stored as NULL")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testRecordWithAKeyThatDoesNotBindFailsBeforeTheClassificationUpdate() throws {
        XCTAssertTrue(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "UPDATE photo_order SET mime_seen", after: "SELECT inspected,mime_seen",
                limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(store.record([:], classifiedUIDs: [Self.long]), "An update that matched no row recorded nothing")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testResolvedMetadataWithAKeyThatDoesNotBindFailsItsPublication() throws {
        XCTAssertTrue(store.synchronize([photo(Self.long)], classifiedUIDs: []))
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "UPDATE photo_order AS o SET published=1",
                after: "UPDATE photo_order SET exact", limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(
            store.recordResolvedMetadata(
                for: Self.long, metadata: TimelineOrderMetadata(exactCaptureTime: Date(timeIntervalSince1970: 501)),
                isClassified: false),
            "A publication that matched no second published nothing")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }
}
