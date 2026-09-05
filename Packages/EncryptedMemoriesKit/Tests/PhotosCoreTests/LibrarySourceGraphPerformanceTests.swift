import Foundation
import XCTest

@testable import PhotosCore

final class LibrarySourceGraphPerformanceTests: XCTestCase {
    /// Opt-in, in-memory production-path benchmark. Fixtures and assertions are outside the timed region.
    /// Run the same release configuration before and after a change; timings are evidence, not CI limits.
    func testLargeInventorySnapshotCost() throws {
        guard ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_SOURCE_GRAPH_BENCHMARK"] == "1" else {
            throw XCTSkip("Set ENCRYPTED_MEMORIES_SOURCE_GRAPH_BENCHMARK=1 to measure source projections")
        }
        for sourceCount in [1, 4] {
            let inventories = (0..<sourceCount).map { sourceIndex in
                LibrarySourceInventory(
                    source: LibrarySource(
                        id: SourceID("source-\(sourceIndex)"),
                        capabilities: [.readMetadata, .readThumbnail, .readContent],
                        precedence: sourceCount - sourceIndex,
                        isIncluded: sourceIndex == 0
                    ),
                    accessState: .available,
                    authority: .authoritative,
                    items: (0..<40_000).map { index in
                        .complete(
                            PhotoItem(
                                uid: PhotoUID(volumeID: "volume", nodeID: "item-\(index + sourceIndex * 10_000)"),
                                captureTime: Date(timeIntervalSince1970: Double(index)),
                                mediaType: "image/heic",
                                isLivePhoto: index.isMultiple(of: 10),
                                relatedVideoID: index.isMultiple(of: 10) ? "motion-\(index)" : nil,
                                burstMemberIDs: index.isMultiple(of: 20) ? ["burst-\(index)"] : []
                            ))
                    }
                )
            }
            let graph = try LibrarySourceGraph(restoring: inventories)
            let expected = graph.snapshot()
            XCTAssertEqual(expected.selectedProjection.timeline.snapshot.count, 40_000)
            XCTAssertEqual(expected.retentionScope.uids.count, 40_000 + (sourceCount - 1) * 10_000)
            var samples: [Double] = []
            for _ in 0..<5 {
                let clock = ContinuousClock()
                let start = clock.now
                let change = graph.snapshot()
                let elapsed = start.duration(to: clock.now).components
                samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                XCTAssertEqual(
                    change.selectedProjection.timeline.snapshot, expected.selectedProjection.timeline.snapshot)
                XCTAssertEqual(
                    change.retentionProjection.timeline.snapshot, expected.retentionProjection.timeline.snapshot)
                XCTAssertEqual(change.analysisScope, expected.analysisScope)
                XCTAssertEqual(change.thumbnailRetentionScope, expected.thumbnailRetentionScope)
                XCTAssertEqual(change.videoRetentionScope, expected.videoRetentionScope)
            }
            print(
                "SourceGraph snapshot sources=\(sourceCount) itemsPerSource=40000 median_ms=\(samples.sorted()[2]) samples_ms=\(samples)"
            )
        }
    }
}
