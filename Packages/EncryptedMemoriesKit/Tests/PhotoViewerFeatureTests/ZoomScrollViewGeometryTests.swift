#if os(macOS)
    import AppKit
    import PhotoViewerCore
    import XCTest
    @testable import PhotoViewerFeature

    @MainActor
    final class ZoomScrollViewGeometryTests: XCTestCase {
        func testIntermediateMagnificationUsesActualMediaEdges() throws {
            let viewport = CGSize(width: 390, height: 844)
            let media = CGSize(width: 1080, height: 1920)
            let scrollView = makeScrollView(viewport: viewport, media: media)

            scrollView.magnification = 2
            scrollView.updateZoomContentGeometry()
            scrollView.layoutSubtreeIfNeeded()

            let fit = ViewerZoomGeometry.aspectFitSize(mediaSize: media, viewportSize: viewport)
            let documentSize = try XCTUnwrap(scrollView.documentView?.frame.size)
            XCTAssertEqual(documentSize.width, fit.width, accuracy: 0.001)
            XCTAssertEqual(documentSize.height, fit.height, accuracy: 0.001)
            XCTAssertEqual(scrollView.contentView.contentInsets.left, 0, accuracy: 0.001)
            XCTAssertEqual(scrollView.contentView.contentInsets.right, 0, accuracy: 0.001)
            XCTAssertEqual(scrollView.contentView.contentInsets.top, 0, accuracy: 0.001)
            XCTAssertEqual(scrollView.contentView.contentInsets.bottom, 0, accuracy: 0.001)

            let visibleDocumentSize = CGSize(
                width: viewport.width / scrollView.magnification,
                height: viewport.height / scrollView.magnification
            )
            let edge = CGPoint(
                x: max(0, fit.width - visibleDocumentSize.width),
                y: max(0, fit.height - visibleDocumentSize.height)
            )
            scrollView.contentView.scroll(to: edge)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            XCTAssertEqual(scrollView.contentView.bounds.origin.x, edge.x, accuracy: 0.001)
            XCTAssertEqual(scrollView.contentView.bounds.origin.y, edge.y, accuracy: 0.001)
        }

        func testRotationRebasesAnchorAndPreservesMagnification() throws {
            let media = CGSize(width: 1600, height: 1200)
            let portrait = CGSize(width: 390, height: 844)
            let landscape = CGSize(width: 844, height: 390)
            let scrollView = makeScrollView(viewport: portrait, media: media)
            scrollView.magnification = 2
            scrollView.updateZoomContentGeometry()

            let oldFit = try XCTUnwrap(scrollView.documentView?.frame.size)
            let oldPhysicalOrigin = CGPoint(x: 240, y: 120)
            scrollView.contentView.scroll(
                to: CGPoint(
                    x: oldPhysicalOrigin.x / scrollView.magnification,
                    y: oldPhysicalOrigin.y / scrollView.magnification
                ))
            let oldAnchor = ViewerZoomGeometry.normalizedVisibleAnchor(
                contentOrigin: oldPhysicalOrigin,
                contentSize: CGSize(
                    width: oldFit.width * scrollView.magnification,
                    height: oldFit.height * scrollView.magnification
                ),
                viewportSize: portrait
            )
            let expectedLandscapeFit = ViewerZoomGeometry.aspectFitSize(mediaSize: media, viewportSize: landscape)
            let expectedLandscapeContent = CGSize(
                width: expectedLandscapeFit.width * scrollView.magnification,
                height: expectedLandscapeFit.height * scrollView.magnification
            )
            let expectedAnchor = ViewerZoomGeometry.normalizedVisibleAnchor(
                contentOrigin: ViewerZoomGeometry.rebasedOrigin(
                    anchor: oldAnchor,
                    contentSize: expectedLandscapeContent,
                    viewportSize: landscape
                ),
                contentSize: expectedLandscapeContent,
                viewportSize: landscape
            )

            scrollView.frame = CGRect(origin: .zero, size: landscape)
            scrollView.contentView.frame = scrollView.bounds
            scrollView.updateZoomContentGeometry()
            scrollView.layoutSubtreeIfNeeded()

            let newFit = try XCTUnwrap(scrollView.documentView?.frame.size)
            XCTAssertNotEqual(newFit, oldFit)
            XCTAssertEqual(scrollView.magnification, 2, accuracy: 0.001)
            let newPhysicalOrigin = CGPoint(
                x: scrollView.contentView.bounds.origin.x * scrollView.magnification,
                y: scrollView.contentView.bounds.origin.y * scrollView.magnification
            )
            let newAnchor = ViewerZoomGeometry.normalizedVisibleAnchor(
                contentOrigin: newPhysicalOrigin,
                contentSize: CGSize(
                    width: newFit.width * scrollView.magnification,
                    height: newFit.height * scrollView.magnification
                ),
                viewportSize: landscape
            )
            XCTAssertEqual(newAnchor.x, expectedAnchor.x, accuracy: 0.01)
            XCTAssertEqual(newAnchor.y, expectedAnchor.y, accuracy: 0.01)
        }

        private func makeScrollView(viewport: CGSize, media: CGSize) -> ZoomScrollView {
            let scrollView = ZoomScrollView(frame: CGRect(origin: .zero, size: viewport))
            scrollView.allowsMagnification = true
            scrollView.minMagnification = 1
            scrollView.maxMagnification = 10
            scrollView.contentView.automaticallyAdjustsContentInsets = false
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.image = NSImage(size: media)
            scrollView.documentView = imageView
            scrollView.layoutSubtreeIfNeeded()
            scrollView.updateZoomContentGeometry()
            return scrollView
        }
    }
#endif
