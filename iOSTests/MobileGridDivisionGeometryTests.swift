import GridCore
import MediaByteCache
import MediaCacheUIKitAdapter
import PhotosCore
import TimelineUIKitAdapter
import UIKit
import XCTest

@testable import TimelineUIKitFeature

final class MobileGridDivisionGeometryTests: XCTestCase {
    @MainActor func testProfileChangeUsesFullWidthSourceTileSizeAndCachesDivisionFacts() throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 867, height: 669)
        window.isHidden = false
        defer { window.isHidden = true }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: directory), loader: ChromeProbeLoader())
        let items = (0..<120).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "division-profile", nodeID: String($0)), captureTime: Date(),
                mediaType: "image/jpeg")
        }
        let host = UIKitTimelineGridHostView(frame: window.bounds)
        let band = CGRect(x: 60, y: 0, width: 40, height: 669)
        host.divisionAreasForTesting = [ReservedRegionArea(frame: band, isActive: true)]
        window.addSubview(host)
        defer {
            host.setActive(false)
            host.removeFromSuperview()
        }
        host.configure(items: items, thumbnailFeed: feed, fillOrder: .topLeading, initialViewportPlacement: .oldest)
        host.layoutIfNeeded()
        let sourceProfile = host.currentProfile()
        let sourceEngine = host.currentEngine(profile: sourceProfile)
        XCTAssertNil(sourceEngine.divisionFrame, "Vertical divisions do not reserve a column gap")
        let sourceWidth = UIKitTimelineGridProfileAdapter.layoutSize(
            forBounds: host.bounds, safeAreaInsets: host.safeAreaInsets
        ).width
        let sourceLevel = sourceProfile.defaultLevel
        #if DEBUG
            let resolutions = host.gridDivisionResolutionCount
            for _ in 0..<100 { _ = host.currentEngine(profile: sourceProfile) }
            XCTAssertEqual(
                host.gridDivisionResolutionCount, resolutions, "A cached engine must not resolve division facts again")
        #endif
        host.frame.size.width = 402
        let targetProfile = host.currentProfile()
        let targetEngine = host.currentEngine(profile: targetProfile)
        let targetWidth = UIKitTimelineGridProfileAdapter.layoutSize(
            forBounds: host.bounds, safeAreaInsets: host.safeAreaInsets
        ).width
        let expected = sourceEngine.closestVisualLevel(
            sourceLevel: sourceLevel, sourceWidth: sourceWidth, in: targetEngine, targetWidth: targetWidth)
        var undivided = sourceEngine
        undivided.divisionFrame = nil
        XCTAssertEqual(
            expected,
            undivided.closestVisualLevel(
                sourceLevel: sourceLevel, sourceWidth: sourceWidth, in: targetEngine, targetWidth: targetWidth),
            "A vertical division keeps the ordinary visual level")
        XCTAssertEqual(host.interactiveLevel, expected, "Profile changes compare the tile sizes actually displayed")
    }

    @MainActor func testVerticalDivisionUsesFullWidthAndKeepsHitTargetsInBothLayoutDirections() throws {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 867, height: 669)
        window.isHidden = false
        defer { window.isHidden = true }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = UIKitThumbnailFeed(cache: ThumbnailCache(rootDirectory: directory), loader: ChromeProbeLoader())
        let items = (0..<120).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "division-probe", nodeID: String($0)), captureTime: Date(),
                mediaType: "image/jpeg")
        }
        let frame = CGRect(x: 0, y: 0, width: 867, height: 669)
        let band = CGRect(x: 455.116, y: 0, width: 40, height: 669)
        let profile = UIKitTimelineGridProfileAdapter().profile(forBounds: frame)
        var previousRects: [CGRect]?
        for direction in [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft] {
            let host = UIKitTimelineGridHostView(frame: frame)
            host.semanticContentAttribute = direction
            host.divisionAreasForTesting = [ReservedRegionArea(frame: band, isActive: true)]
            window.addSubview(host)
            defer {
                host.setActive(false)
                host.removeFromSuperview()
            }
            host.configure(
                items: items, thumbnailFeed: feed, level: profile.defaultLevel, gridProfile: profile,
                fillOrder: .topLeading, initialViewportPlacement: .oldest)
            host.setNeedsLayout()
            host.layoutIfNeeded()
            let plan = try XCTUnwrap(host.accessibilityFramePlan())
            XCTAssertEqual(plan.columns, 6)
            XCTAssertFalse(plan.visibleSlots.isEmpty)
            let row = plan.visibleSlots.filter { $0.row == 0 }
            XCTAssertEqual(row.map(\.slotRect.minX).min(), 0)
            XCTAssertEqual(try XCTUnwrap(row.map(\.slotRect.maxX).max()), frame.width, accuracy: 1e-9)
            for slot in plan.visibleSlots {
                let point = CGPoint(x: slot.slotRect.midX, y: slot.slotRect.midY)
                XCTAssertEqual(host.item(at: point)?.uid, items[slot.index].uid)
            }
            let witness = try XCTUnwrap(plan.visibleSlots.first)
            XCTAssertNotNil(host.item(at: CGPoint(x: band.midX, y: witness.slotRect.midY)))
            let rects = plan.visibleSlots.map(\.slotRect)
            if let previousRects { XCTAssertEqual(rects, previousRects, "Hardware frames must not be mirrored twice") }
            previousRects = rects
            host.scrollView.setContentOffset(CGPoint(x: 0, y: 420), animated: false)
            let anchor = try XCTUnwrap(host.currentScrollAnchor())
            for areas in [
                [], [ReservedRegionArea(frame: band, isActive: false)],
                [ReservedRegionArea(frame: band, isActive: true)],
            ] {
                host.divisionAreasForTesting = areas
                host.layoutIfNeeded()
                let changed = try XCTUnwrap(host.accessibilityFramePlan())
                let anchored = try XCTUnwrap(changed.visibleSlots.first { items[$0.index].uid == anchor.itemID })
                XCTAssertEqual(anchored.slotRect.minY - host.scrollView.contentOffset.y, anchor.topOffset, accuracy: 1)
            }
            host.divisionAreasForTesting = []
            host.layoutIfNeeded()
            host.zoomInOneStep()
            let transaction = try XCTUnwrap(host.zoomTransaction)
            host.divisionAreasForTesting = [
                ReservedRegionArea(frame: CGRect(x: 0, y: 300, width: 867, height: 40), isActive: true)
            ]
            host.layoutIfNeeded()
            XCTAssertEqual(host.zoomTransaction, transaction, "A horizontal fold does not change the photo geometry")
            host.cancelLiveZoomState()
        }
    }
}
