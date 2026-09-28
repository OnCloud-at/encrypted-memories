import CoreGraphics
import Testing

@testable import GridCore

/// The scroll anchor is the first photo that the translucent bars do not hide, so a narrower grid keeps it on screen.
/// Measured case: iPhone Duo outer display, two 233-pt columns, scrolled to y 420 under an 82-pt bar.
@Suite struct GridScrollAnchorPolicyTests {
    private struct Slot: Equatable {
        let index: Int
        let frame: CGRect
    }

    private func slots(side: CGFloat, pitch: CGFloat, columns: Int, rows: ClosedRange<Int>) -> [Slot] {
        rows.flatMap { row in
            (0..<columns).map {
                Slot(index: row * columns + $0, frame: CGRect(x: 0, y: CGFloat(row) * pitch, width: side, height: side))
            }
        }
    }

    private func anchor(_ slots: [Slot], top: CGFloat, bottom: CGFloat) -> Slot? {
        GridScrollAnchorPolicy.anchor(among: slots, visibleTop: top, visibleBottom: bottom, frame: \.frame)
    }

    @Test func aPhotoTheBarMostlyCoversDoesNotAnchorThePosition() {
        // Rows at 235-pt pitch; the viewport starts at 420 and the bar ends at 502. Row 1 (top 235) and row 2 (top 470)
        // are under the bar; row 3 (top 705) is the first whose top is visible.
        let visible = slots(side: 233, pitch: 235, columns: 2, rows: 1...4)
        #expect(anchor(visible, top: 420 + 82, bottom: 420 + 644)?.index == 6)
    }

    @Test func withoutABarTheTopVisibleRowAnchorsWhenItsTopIsVisible() {
        let visible = slots(side: 100, pitch: 102, columns: 3, rows: 2...5)
        #expect(anchor(visible, top: 204, bottom: 900)?.index == 6)
    }

    @Test func aRowThatStartsHalfAPointAboveTheLineStillCounts() {
        let visible = slots(side: 100, pitch: 100.4, columns: 1, rows: 1...2)
        #expect(anchor(visible, top: 100.8, bottom: 900)?.index == 1)
    }

    @Test func aPhotoThatStartsUnderTheBottomBarDoesNotAnchor() {
        // 400-pt tiles in a 450-pt window with 82/50-pt bars, scrolled to 1170: row 3 starts under the top bar and
        // reaches into the visible area, row 4 starts under the bottom bar. Row 3 anchors, not the hidden row 4.
        let visible = slots(side: 400, pitch: 400, columns: 1, rows: 3...4)
        #expect(anchor(visible, top: 1170 + 82, bottom: 1170 + 400)?.index == 3)
    }

    @Test func withTilesTallerThanTheVisibleAreaThePhotoInViewAnchors() {
        // Scrolled to 1580 with the same bars: no row starts in the visible area (1662-1980). Row 3 (1200-1600) is
        // hidden behind the top bar; row 4 (1600-2000) fills the visible area and anchors.
        let visible = slots(side: 400, pitch: 400, columns: 1, rows: 3...5)
        #expect(anchor(visible, top: 1580 + 82, bottom: 1580 + 400)?.index == 4)
    }

    @Test func withoutAnyPhotoInViewTheTopmostOneAnchors() {
        let visible = slots(side: 50, pitch: 60, columns: 2, rows: 0...0)
        #expect(anchor(visible, top: 120, bottom: 300)?.index == 0)
        #expect(anchor([], top: 0, bottom: 900) == nil)
    }
}
