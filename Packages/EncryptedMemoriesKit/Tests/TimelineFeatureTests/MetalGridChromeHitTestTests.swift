import CoreGraphics
import Testing

@testable import TimelineFeature

@Suite("Grid events under window chrome")
struct MetalGridChromeHitTestTests {
    @Test func eventsUnderTheToolbarNeverReachTheGrid() {
        #expect(MetalGridScrollHost.declinesEvent(atX: 400, distanceFromTop: 10, leadingInset: 0, topInset: 52))
        #expect(MetalGridScrollHost.declinesEvent(atX: 400, distanceFromTop: 51.9, leadingInset: 0, topInset: 52))
        #expect(!MetalGridScrollHost.declinesEvent(atX: 400, distanceFromTop: 52, leadingInset: 0, topInset: 52))
    }

    @Test func eventsUnderTheSidebarNeverReachTheGrid() {
        #expect(MetalGridScrollHost.declinesEvent(atX: 120, distanceFromTop: 300, leadingInset: 240, topInset: 52))
        #expect(!MetalGridScrollHost.declinesEvent(atX: 240, distanceFromTop: 300, leadingInset: 240, topInset: 52))
    }

    @Test func withoutChromeEveryEventReachesTheGrid() {
        #expect(!MetalGridScrollHost.declinesEvent(atX: 0, distanceFromTop: 0, leadingInset: 0, topInset: 0))
    }
}
