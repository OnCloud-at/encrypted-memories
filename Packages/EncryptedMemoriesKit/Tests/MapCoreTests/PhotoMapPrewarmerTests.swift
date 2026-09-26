import MapKit
import Testing

@testable import MapCore

@Suite("Map prewarm framing")
struct PhotoMapPrewarmerTests {
    @Test func theSnapshotCoversWhatTheMapShowsAfterFramingWithPadding() throws {
        let core = MKMapRect(x: 1_000, y: 2_000, width: 840, height: 540)

        let visible = try #require(
            PhotoMapPrewarmer.visibleMapRect(framing: core, in: CGSize(width: 1_000, height: 700)))

        // 840 map points fit into 1000 - 160 screen points, so one screen point shows one map point.
        #expect(abs(visible.width - 1_000) < 0.001)
        #expect(abs(visible.height - 700) < 0.001)
        #expect(abs(visible.midX - core.midX) < 0.001)
        #expect(abs(visible.midY - core.midY) < 0.001)
        #expect(visible.contains(core))
    }

    @Test func theTighterAxisDecidesTheZoom() throws {
        let tall = MKMapRect(x: 0, y: 0, width: 100, height: 1_080)

        let visible = try #require(
            PhotoMapPrewarmer.visibleMapRect(framing: tall, in: CGSize(width: 1_000, height: 700)))

        // 1080 map points into 700 - 160 screen points: two map points per screen point.
        #expect(abs(visible.height - 1_400) < 0.001)
        #expect(abs(visible.width - 2_000) < 0.001)
    }

    @Test func aViewSmallerThanItsPaddingLoadsNothing() {
        let core = MKMapRect(x: 0, y: 0, width: 10, height: 10)
        #expect(PhotoMapPrewarmer.visibleMapRect(framing: core, in: .zero) == nil)
        #expect(PhotoMapPrewarmer.visibleMapRect(framing: core, in: CGSize(width: 150, height: 900)) == nil)
    }
}
