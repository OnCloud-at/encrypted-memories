import AppKit
import GridCore
import Metal
import PhotosCore
import XCTest

@testable import TimelineFeature

@MainActor
final class TimelineOrderGridTests: XCTestCase {
    func testVisibleCorrectionWaitsUntilOffscreenAndKeepsTheScrollAnchor() throws {
        _ = NSApplication.shared
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let items = (0..<3_000).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "order-test", nodeID: String($0)),
                captureTime: Date(timeIntervalSince1970: Double(500 + $0 / 2)), mediaType: "image/jpeg")
        }
        let host = try XCTUnwrap(
            MetalGridScrollHost(device: device, dataSource: OrderGridSource(items), gridProfile: .testRegularTimeline))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            host.removeFromSuperview()
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        host.scrollToFlatIndex(900)
        let y = try XCTUnwrap(
            host.coordinator.settleScrollOffsetY(
                toLevel: host.coordinator.level,
                anchorContentPoint: CGPoint(x: 400, y: host.coordinator.scrollOriginY + 300),
                viewportPoint: CGPoint(x: 20, y: 300)))
        host.coordinator.clipView?.scroll(to: CGPoint(x: 0, y: y))
        let phase = try XCTUnwrap(host.coordinator.currentPhase())
        let before = try XCTUnwrap(host.currentScrollAnchor())
        let pair = try XCTUnwrap(host.coordinator.flatIndex(forUID: before.itemID)) / 2 * 2
        var corrected = items
        corrected[pair].timelineOrder = .init(exactCaptureTime: items[pair].captureTime.addingTimeInterval(0.8))
        corrected[pair + 1].timelineOrder = .init(exactCaptureTime: items[pair + 1].captureTime.addingTimeInterval(0.1))
        corrected.sort(by: TimelineOrder.areInIncreasingOrder)
        let coordinator = MetalProductionGridView.Coordinator()
        coordinator.host = host
        coordinator.allItems = items
        coordinator.dataRevision = 1
        let receive = {
            coordinator.receiveContent(
                items: corrected, revision: 2, routeGeneration: 0,
                initialViewport: .newest, markers: [], makeSource: { OrderGridSource(corrected) })
        }
        receive()
        XCTAssertEqual(coordinator.allItems, items)
        XCTAssertEqual(host.currentScrollAnchor()?.itemID, before.itemID)
        XCTAssertEqual(try XCTUnwrap(host.currentScrollAnchor()).topOffset, before.topOffset, accuracy: 0.5)
        receive()
        XCTAssertEqual(coordinator.allItems, items)

        var scrolledAnchor: GridScrollAnchor<PhotoUID>?
        host.onViewportChanged = {
            if scrolledAnchor == nil { scrolledAnchor = host.currentScrollAnchor() }
            coordinator.viewportChanged()
        }
        host.scrollToFlatIndex(1_350)
        XCTAssertEqual(coordinator.allItems, corrected)
        XCTAssertEqual(host.coordinator.currentPhase(), phase)
        XCTAssertEqual(host.coordinator.uid(atFlatIndex: pair), corrected[pair].uid)
        let expected = try XCTUnwrap(scrolledAnchor)
        XCTAssertEqual(host.currentScrollAnchor()?.itemID, expected.itemID)
        XCTAssertEqual(try XCTUnwrap(host.currentScrollAnchor()).topOffset, expected.topOffset, accuracy: 0.5)
    }
}

@MainActor
private final class OrderGridSource: MetalGridDataSource {
    let label = "order-test"
    let sectionCounts: [Int]
    let flatUIDs: [PhotoUID]
    var onImagesAvailable: (() -> Void)?
    init(_ items: [PhotoItem]) {
        sectionCounts = [items.count]
        flatUIDs = items.map(\.uid)
    }
    func hasImage(for uid: PhotoUID) -> Bool { false }
    func image(for uid: PhotoUID) -> CGImage? { nil }
    func warm(_ requests: [ThumbnailRequest]) {}
}
