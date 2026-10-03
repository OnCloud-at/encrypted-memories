import Foundation
import XCTest

@testable import PhotosCore

private final class TrailLibrarySource: LibrarySyncSupportSource {
    func librarySyncSupportSnapshot(now: Date) async -> LibrarySyncSupportSnapshot? { nil }
}

final class SupportEventTrailTests: XCTestCase {
    private let secret = "/private/person/IMG_0001.HEIC"

    func testTheTrailKeepsTheNewestEventsAndCountsTheDroppedOnes() {
        let trail = SupportEventTrail(capacity: 3)
        for count in 1...5 { trail.record(.libraryLoadSucceeded, sourcePath: .authoritative, count: count) }
        let export = trail.export(hashingWith: SupportReportIdentifierHasher())
        XCTAssertEqual(export.events.map(\.count), [3, 4, 5])
        XCTAssertEqual(export.dropped, 2)
    }

    func testSubjectsLeaveOnlyAsTheHashOfTheReport() {
        let trail = SupportEventTrail()
        trail.record(.backupRowParked, subject: secret, resourceKind: .primary, reason: .network)
        trail.record(.editReplaced, subject: secret)
        trail.record(.editKept, subject: "another-photo")
        let hasher = SupportReportIdentifierHasher()
        let events = trail.export(hashingWith: hasher).events
        XCTAssertEqual(events.map(\.subject), [hasher.hash(secret), hasher.hash(secret), hasher.hash("another-photo")])
        XCTAssertNotEqual(events[0].subject, SupportReportIdentifierHasher().hash(secret))
        XCTAssertEqual(events[0].reason, .network)
        XCTAssertEqual(events[0].resourceKind, .primary)
    }

    func testTheReportHoldsTheTrailAndThePendingGridWithoutAnyIdentifier() async throws {
        let trail = SupportEventTrail()
        trail.record(.backupRowParked, subject: secret, resourceKind: .primary, reason: .accountStorage)
        trail.record(.libraryLoadFailed, sourcePath: .continuity, errorKind: .network)
        let sources = SupportDiagnosticsSources(trail: trail)
        sources.publishPendingGrid { grid in
            grid.merges = 4
            grid.pendingTiles = 2
            grid.remotePhotosHidden = 1
        }
        let data = try await SupportDiagnosticsExporter.makeJSONData(sources: sources, trail: trail)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("IMG_0001"))
        XCTAssertFalse(text.contains("private"))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let recent = try XCTUnwrap(report["recentEvents"] as? [String: Any])
        let events = try XCTUnwrap(recent["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["kind"] as? String }, ["backupRowParked", "libraryLoadFailed"])
        XCTAssertEqual(events[0]["reason"] as? String, "accountStorage")
        XCTAssertEqual((events[0]["subject"] as? String)?.count, 64)
        XCTAssertEqual(events[1]["errorKind"] as? String, "network")
        let backup = try XCTUnwrap(report["backup"] as? [String: Any])
        let grid = try XCTUnwrap(backup["pendingGrid"] as? [String: Any])
        XCTAssertEqual(grid["merges"] as? Int, 4)
        XCTAssertEqual(grid["pendingTiles"] as? Int, 2)
        XCTAssertEqual(grid["remotePhotosHidden"] as? Int, 1)
    }

    func testSigningOutClearsTheTrailButAnOldSessionDoesNot() {
        let trail = SupportEventTrail()
        let sources = SupportDiagnosticsSources(trail: trail)
        let old = TrailLibrarySource()
        let current = TrailLibrarySource()
        sources.registerLibrary(old)
        sources.registerLibrary(current)
        trail.record(.editWaiting, subject: secret)
        sources.publishPendingGrid { $0.pendingTiles = 3 }
        sources.unregisterLibrary(old)
        XCTAssertEqual(trail.export(hashingWith: SupportReportIdentifierHasher()).events.count, 1)
        sources.unregisterLibrary(current)
        XCTAssertTrue(trail.export(hashingWith: SupportReportIdentifierHasher()).events.isEmpty)
        XCTAssertEqual(sources.pendingGridSnapshot(), PendingGridSupportSnapshot())
        withExtendedLifetime((old, current)) {}
    }
}
