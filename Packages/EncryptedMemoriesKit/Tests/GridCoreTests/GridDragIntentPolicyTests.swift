import CoreGraphics
import GridCore
import Testing

@Suite struct GridDragIntentPolicyTests {
    @Test func photoEdgesBelongToMarqueeButInteriorStillDrags() {
        let photo = CGRect(x: 100, y: 200, width: 120, height: 80)
        for point in [
            CGPoint(x: 101, y: 240), CGPoint(x: 219, y: 240),
            CGPoint(x: 160, y: 201), CGPoint(x: 160, y: 279),
        ] {
            #expect(!GridDragIntentPolicy.startsDragOut(at: point, visiblePhotoRect: photo))
        }
        #expect(GridDragIntentPolicy.startsDragOut(at: CGPoint(x: 160, y: 240), visiblePhotoRect: photo))
    }

    @Test func letterboxAndSmallTilesKeepUsefulInterior() {
        let slot = CGRect(x: 0, y: 0, width: 30, height: 30)
        let photo = TileContentFitter.fit(slotRect: slot, mediaAspect: 2, mode: .aspectFit).contentRect
        #expect(!GridDragIntentPolicy.startsDragOut(at: CGPoint(x: 15, y: 2), visiblePhotoRect: photo))
        #expect(!GridDragIntentPolicy.startsDragOut(at: CGPoint(x: 15, y: photo.minY + 1), visiblePhotoRect: photo))
        #expect(GridDragIntentPolicy.startsDragOut(at: CGPoint(x: 15, y: 15), visiblePhotoRect: photo))
        #expect(GridDragIntentPolicy.dragOutRect(visiblePhotoRect: .zero).isNull)
    }
}
