import AppKit
import GridCore
import MetalKit
import PhotosCore
import Testing

@testable import TimelineFeature

/// Where the real grid host puts the clip view after its scroll commands, level changes and sidebar settle. The
/// host clamps every target into the content, moves the clip view and tells the scroll view; the scroller must
/// follow the clip view.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalGridScrollHostScrollTests {
    private static let count = 3_000

    @Test func scrollToFlatIndexPutsTheRowNearTheTopAndClampsAtBothEnds() throws {
        let fixture = try Fixture()
        let host = fixture.host
        for index in [0, 1, 900, 2_000, Self.count - 1] {
            host.scrollToFlatIndex(index)
            let rect = try #require(host.coordinator.cellContentRect(forFlatIndex: index))
            fixture.expectClip(at: min(max(0, rect.minY - 24), fixture.maxScrollY), "index \(index)")
        }
        #expect(fixture.maxScrollY > 1_000, "the fixture is long enough to clamp at the bottom")
    }

    @Test func scrollToItemCentersThePhotoAndClampsAtBothEnds() throws {
        let fixture = try Fixture()
        let host = fixture.host
        for index in [0, 5, 900, 2_000, Self.count - 1] {
            host.scrollToItem(Fixture.uid(index))
            let rect = try #require(host.coordinator.cellContentRect(forFlatIndex: index))
            let clipHeight = fixture.clipView.bounds.height
            fixture.expectClip(at: min(max(0, rect.midY - clipHeight / 2), fixture.maxScrollY), "item \(index)")
        }
    }

    @Test func aFlatIndexScrollEndsWithTheViewportAnnouncedAtTheTarget() throws {
        let fixture = try Fixture()
        let host = fixture.host
        var clipYAtAnnouncement: [CGFloat] = []
        host.onViewportChanged = { clipYAtAnnouncement.append(fixture.clipView.bounds.origin.y) }
        host.scrollToFlatIndex(900)
        let rect = try #require(host.coordinator.cellContentRect(forFlatIndex: 900))
        #expect(abs((clipYAtAnnouncement.last ?? -1) - min(max(0, rect.minY - 24), fixture.maxScrollY)) < 0.01)
    }

    @Test func scrollToBottomPinsTheClipToTheEnd() throws {
        let fixture = try Fixture()
        fixture.host.scrollToFlatIndex(900)
        fixture.host.scrollToBottom()
        fixture.expectClip(at: fixture.maxScrollY, "bottom")
    }

    /// The clip positions below were recorded from the host before its scroll helpers were extracted: the window
    /// is 1,080 x 720 and the single section holds 3,000 photos. Both zoom paths end bottom-pinning.
    private static let clickZoomClipY: CGFloat = 32_815
    private static let overviewDissolveClipY: CGFloat = 3_799
    private static let settledRebaseClipY: CGFloat = 32_967
    private static let sidebarSettleClipY: CGFloat = 26_083

    /// One section: the toolbar step to a normal level runs the click transition, the step across the overview
    /// boundary runs the overview dissolve.
    @Test func zoomButtonsRunTheClickTransitionAndTheOverviewDissolve() throws {
        let fixture = try Fixture()
        let host = fixture.host
        let coordinator = host.coordinator
        host.scrollToFlatIndex(1_500)
        let start = coordinator.level

        host.setLevel(start - 1)
        #expect(coordinator.level == start - 1)
        #expect(coordinator.gridTransition.activeKind == .click)
        #expect(abs(fixture.clipView.bounds.origin.y - Self.clickZoomClipY) < 1)

        host.setLevel(start)
        host.setLevel(start + 1)
        #expect(coordinator.level == start + 1)
        #expect(coordinator.isOverviewClickDissolving)
        #expect(abs(fixture.clipView.bounds.origin.y - Self.overviewDissolveClipY) < 1)
    }

    /// Two sections: no single-section lattice exists, so the level change falls back to the settled rebase.
    @Test func aZoomWithoutATransitionRebasesTheClipToTheAnchor() throws {
        let fixture = try Fixture(sections: [1_500, 1_500])
        let host = fixture.host
        let coordinator = host.coordinator
        host.scrollToFlatIndex(1_500)
        let start = coordinator.level
        host.setLevel(start - 1)
        #expect(coordinator.level == start - 1)
        #expect(coordinator.gridTransition.activeKind == nil)
        #expect(abs(fixture.clipView.bounds.origin.y - Self.settledRebaseClipY) < 1)
    }

    /// A level change at either end of the content: the anchored scroll may leave the content, and the host
    /// clamps it. Single section (click transition, overview dissolve) and two sections (settled rebase).
    @Test func zoomButtonsAtTheEndsOfTheContentKeepTheClipInsideIt() throws {
        for sections in [[Self.count], [1_500, 1_500]] {
            for index in [0, Self.count - 1] {
                for step in [-1, 1, 2] {
                    let fixture = try Fixture(sections: sections)
                    let host = fixture.host
                    host.scrollToFlatIndex(index)
                    let start = host.coordinator.level
                    host.setLevel(start + step)
                    let y = fixture.clipView.bounds.origin.y
                    #expect(host.coordinator.level == start + step)
                    #expect(
                        y >= 0 && y <= fixture.maxScrollY,
                        "sections \(sections.count), index \(index), step \(step): y \(y)")
                }
            }
        }
    }

    /// Zooming out from a level with the anchor at either end of the content: the transition returns the anchored
    /// scroll unclamped (it is negative at the top), and the host clamps it into the content.
    @Test func zoomOutAtTheEndsOfTheContentKeepsTheClipInsideIt() throws {
        for index in [0, Self.count - 1] {
            let fixture = try Fixture()
            let host = fixture.host
            let start = host.coordinator.level
            host.setLevel(start - 1)
            host.scrollToFlatIndex(index)
            host.setLevel(start)
            #expect(host.coordinator.level == start)
            let y = fixture.clipView.bounds.origin.y
            #expect(y >= 0 && y <= fixture.maxScrollY, "index \(index): y \(y) of \(fixture.maxScrollY)")
            if index == 0 { #expect(abs(y) < 0.5) }
        }
    }

    /// A bottom-pinned grid that a sidebar transition settles is no longer pinned: photos added afterwards leave the
    /// clip where the settle put it instead of pulling it to the new bottom.
    @Test func theSidebarSettleEndsBottomPinning() throws {
        let fixture = try Fixture(visibleToThePump: true)
        let host = fixture.host
        var now: CFTimeInterval = 0
        host.sidebarClock = { now }
        host.eventLeadingInset = 240  // arms the grid
        host.layoutSubtreeIfNeeded()
        host.scrollToBottom()
        host.eventLeadingInset = 0
        #expect(host.coordinator.isSidebarResizing)
        now += 0.3
        host.step()
        #expect(!host.coordinator.isSidebarResizing)
        let settled = fixture.clipView.bounds.origin.y

        host.setDataSource(StubMetalGridDataSource(sections: [Self.count + 300], volumeID: "scroll"))
        host.layoutSubtreeIfNeeded()
        #expect(fixture.maxScrollY > settled + 100, "the added photos extend the content")
        #expect(abs(fixture.clipView.bounds.origin.y - settled) < 1, "the clip stays where the settle put it")
    }

    /// The sidebar transition ends on the clock; the host then settles the clip on the bottom-anchored scroll.
    @Test func theSidebarSettleMovesTheClipToTheSettledScroll() throws {
        let fixture = try Fixture(visibleToThePump: true)
        let host = fixture.host
        var now: CFTimeInterval = 0
        host.sidebarClock = { now }
        host.eventLeadingInset = 240  // arms the grid
        host.layoutSubtreeIfNeeded()
        host.scrollToFlatIndex(1_500)
        host.eventLeadingInset = 0
        #expect(host.coordinator.isSidebarResizing)
        now += 0.3
        host.step()
        #expect(!host.coordinator.isSidebarResizing)
        #expect(abs(fixture.clipView.bounds.origin.y - Self.sidebarSettleClipY) < 1)
        fixture.expectClip(at: fixture.clipView.bounds.origin.y, "sidebar settle")
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let host: MetalGridScrollHost
        let window: NSWindow

        init(sections: [Int] = [MetalGridScrollHostScrollTests.count], visibleToThePump: Bool = false) throws {
            _ = NSApplication.shared
            let device = try #require(MTLCreateSystemDefaultDevice())
            host = try #require(
                MetalGridScrollHost(
                    device: device, dataSource: StubMetalGridDataSource(sections: sections, volumeID: "scroll"),
                    gridProfile: .testRegularTimeline))
            let rect = NSRect(x: 0, y: 0, width: 1_080, height: 720)
            window =
                visibleToThePump
                ? PumpWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: true)
                : NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
        }

        deinit {
            MainActor.assumeIsolated { window.contentView = nil }
        }

        static func uid(_ index: Int) -> PhotoUID { PhotoUID(volumeID: "scroll", nodeID: "\(index)") }

        var clipView: NSClipView { host.coordinator.clipView! }
        var scrollView: NSScrollView { clipView.superview as! NSScrollView }

        /// Content height minus the visible height: the largest valid clip origin.
        var maxScrollY: CGFloat {
            max(0, (clipView.documentView?.frame.height ?? 0) - clipView.bounds.height)
        }

        /// The clip origin is `y`, and the vertical scroller shows the same position.
        func expectClip(at y: CGFloat, _ label: String) {
            #expect(abs(clipView.bounds.origin.y - y) < 0.01, "\(label): clip y \(clipView.bounds.origin.y) vs \(y)")
            if maxScrollY > 0, let scroller = scrollView.verticalScroller {
                #expect(
                    abs(scroller.doubleValue - Double(y / maxScrollY)) < 0.001,
                    "\(label): scroller \(scroller.doubleValue) vs \(Double(y / maxScrollY))")
            }
        }
    }
}

/// A window that the host sees as visible, so its frame pump runs although nobody looks at it.
private final class PumpWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}
