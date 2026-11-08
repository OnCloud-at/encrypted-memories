import XCTest

@testable import GridCore

@MainActor
final class GridProxyContentReadyTests: XCTestCase {
    func testContentReadinessRepeatsForNewDataGenerations() {
        let proxy = GridProxy<String>()
        var revisions: [UInt64] = []
        proxy.onContentReady = { revisions.append($0) }

        proxy.reportContentReady(revision: 4)
        proxy.reportContentReady(revision: 7)

        XCTAssertEqual(revisions, [4, 7])
    }

    func testLatestContentReadinessIsReplayedAfterHandlerInstallation() {
        let proxy = GridProxy<String>()
        var revisions: [UInt64] = []

        proxy.reportContentReady(revision: 4)
        proxy.reportContentReady(revision: 7)
        proxy.onContentReady = { revisions.append($0) }

        XCTAssertEqual(revisions, [7])
        proxy.reportContentReady(revision: 9)
        XCTAssertEqual(revisions, [7, 9])
    }

    func testInvalidationDiscardsUndeliveredReadinessAndAllowsNextFrame() {
        let proxy = GridProxy<String>()
        proxy.reportContentReady(revision: 4)
        proxy.invalidatePendingContentReady()
        var revisions: [UInt64] = []
        proxy.onContentReady = { revisions.append($0) }
        XCTAssertEqual(revisions, [])
        proxy.reportContentReady(revision: 7)
        XCTAssertEqual(revisions, [7])
    }
}
