import Foundation
import XCTest

@testable import PhotosCore

private actor SeededLibrarySupportSource: LibrarySyncSupportSource {
    func librarySyncSupportSnapshot(now: Date) -> LibrarySyncSupportSnapshot? {
        LibrarySyncSupportSnapshot(
            lastSuccessfulLoad: .init(timestamp: now, sourcePath: .authoritative),
            lastFailedLoad: .init(timestamp: now, sourcePath: .continuity, errorKind: .inventoryVisibility),
            storedEventCursorAgeSeconds: 120, storedPhotoCount: 8, listedPhotoCount: 10,
            photosTrashedHereAwaitingLibrary: 2)
    }
}

private final class SeededQueueSupportSource: BackupQueueSupportSource {
    let total: Int
    init(total: Int) { self.total = total }
    func backupSupportSnapshot() -> BackupQueueSupportSnapshot {
        var result = BackupQueueSupportSnapshot()
        result.isAvailable = true
        result.total = total
        return result
    }
}

final class SupportDiagnosticsSectionsTests: XCTestCase {
    func testSeededLibrarySectionAndEmptyBackupSections() async throws {
        let sources = SupportDiagnosticsSources()
        let library = SeededLibrarySupportSource()
        sources.registerLibrary(library)
        let data = try await SupportDiagnosticsExporter.makeJSONData(sources: sources)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sync = try XCTUnwrap(report["librarySync"] as? [String: Any])
        XCTAssertEqual(sync["storedEventCursorAgeSeconds"] as? Double, 120)
        XCTAssertEqual(sync["storedPhotoCount"] as? Int, 8)
        XCTAssertEqual(sync["listedPhotoCount"] as? Int, 10)
        XCTAssertEqual(sync["photosTrashedHereAwaitingLibrary"] as? Int, 2)
        let success = try XCTUnwrap(sync["lastSuccessfulLoad"] as? [String: Any])
        let failure = try XCTUnwrap(sync["lastFailedLoad"] as? [String: Any])
        XCTAssertEqual(success["sourcePath"] as? String, "authoritative")
        XCTAssertEqual(failure["sourcePath"] as? String, "continuity")
        XCTAssertEqual(failure["errorKind"] as? String, "inventoryVisibility")
        let backup = try XCTUnwrap(report["backup"] as? [String: Any])
        XCTAssertEqual((backup["queues"] as? [Any])?.count, 0)
        XCTAssertEqual((backup["editReplacements"] as? [Any])?.count, 0)
        // Part 1 has no unavoidable identifiers, and therefore exports no salted hashes yet.
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("salt"))
        withExtendedLifetime(library) {}
    }

    func testSourcesDeduplicateStoresAndDoNotRetainTheirOwners() {
        let sources = SupportDiagnosticsSources()
        let first = SeededQueueSupportSource(total: 1)
        sources.registerQueue(first, key: "same-private-path")
        do {
            let second = SeededQueueSupportSource(total: 2)
            sources.registerQueue(second, key: "same-private-path")
            XCTAssertEqual(sources.queueSnapshots().map(\.total), [2])
            withExtendedLifetime(second) {}
        }
        XCTAssertEqual(sources.queueSnapshots().map(\.total), [1])
        withExtendedLifetime(first) {}
    }

    func testOldSessionShutdownCannotClearTheNewSession() async {
        let sources = SupportDiagnosticsSources()
        let old = SeededLibrarySupportSource()
        let current = SeededLibrarySupportSource()
        sources.registerLibrary(old)
        sources.registerLibrary(current)
        let queue = SeededQueueSupportSource(total: 3)
        sources.registerQueue(queue, key: "private-path")
        sources.unregisterLibrary(old)
        XCTAssertEqual(sources.queueSnapshots().map(\.total), [3])
        sources.unregisterLibrary(current)
        XCTAssertTrue(sources.queueSnapshots().isEmpty)
        let library = await sources.librarySnapshot(now: Date())
        XCTAssertNil(library.lastSuccessfulLoad)
        withExtendedLifetime(queue) {}
    }

    func testIdentifierHashIsStableWithinReportAndDifferentBetweenReports() {
        let first = SupportReportIdentifierHasher()
        let second = SupportReportIdentifierHasher()
        let identifier = "/private/person/private-photo.jpg"
        XCTAssertEqual(first.hash(identifier), first.hash(identifier))
        XCTAssertNotEqual(first.hash(identifier), second.hash(identifier))
        XCTAssertNotEqual(first.hash(identifier), first.hash("another-photo"))
        XCTAssertEqual(first.hash(identifier).count, 64)
        XCTAssertFalse(first.hash(identifier).contains("private"))
    }
}
