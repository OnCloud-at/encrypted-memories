import CoreGraphics
import Testing

@testable import GridCore

/// Synthetic reserved regions: the vertical fold of a partially open iPhone Duo in the book pose, the horizontal
/// fold of the tabletop pose, and a camera occlusion. No device reports them in tests, so the shared policy is
/// checked on geometry alone.
@Suite struct ReservedRegionLayoutTests {
    private let tile = CGRect(x: 100, y: 200, width: 100, height: 100)
    private let side: CGFloat = 22
    private let inset: CGFloat = 6

    private let viewport = CGRect(x: 0, y: 0, width: 900, height: 900)

    private func layout(_ areas: ReservedRegionArea...) -> ReservedRegionLayout {
        ReservedRegionLayout(areas: areas, bounds: viewport)
    }

    private func division(_ frame: CGRect) -> ReservedRegionArea {
        ReservedRegionArea(kind: .division, frame: frame, isActive: true)
    }

    @Test func withoutRegionsTheBadgeStaysBottomTrailing() {
        #expect(ReservedRegionLayout.none.badgeCorner(in: tile, side: side, inset: inset) == .bottomTrailing)
        #expect(
            TileCorner.bottomTrailing.badgeRect(in: tile, side: side, inset: inset)
                == CGRect(x: 172, y: 272, width: 22, height: 22))
    }

    @Test func inactiveRegionsAreIgnored() {
        // A fully open device keeps the folding region inactive: nothing moves.
        let open = layout(
            ReservedRegionArea(kind: .division, frame: CGRect(x: 170, y: 0, width: 40, height: 900), isActive: false))
        #expect(open.isEmpty)
        #expect(open.badgeCorner(in: tile, side: side, inset: inset) == .bottomTrailing)
    }

    @Test func aVerticalFoldOverTheTrailingEdgeMovesTheBadgeToTheLeadingSide() {
        // Book pose: the fold crosses the tile's trailing quarter from top to bottom.
        let fold = layout(
            ReservedRegionArea(kind: .division, frame: CGRect(x: 170, y: 0, width: 40, height: 900), isActive: true))
        let corner = fold.badgeCorner(in: tile, side: side, inset: inset)
        #expect(corner == .bottomLeading)
        #expect(fold.isClear(corner.badgeRect(in: tile, side: side, inset: inset)))
    }

    @Test func aHorizontalFoldOverTheBottomEdgeMovesTheBadgeToTheTop() {
        // Tabletop pose: the fold crosses the tile's lower quarter; the top-trailing corner is free.
        let fold = layout(
            ReservedRegionArea(kind: .division, frame: CGRect(x: 0, y: 270, width: 900, height: 40), isActive: true))
        #expect(fold.badgeCorner(in: tile, side: side, inset: inset) == .topTrailing)
    }

    @Test func aCameraOcclusionCountsLikeAFold() {
        let camera = layout(
            ReservedRegionArea(kind: .occlusion, frame: CGRect(x: 165, y: 265, width: 37, height: 37), isActive: true))
        #expect(camera.badgeCorner(in: tile, side: side, inset: inset) == .topTrailing)
    }

    @Test func aTileCoveredInEveryCornerKeepsTheBadgeBottomTrailing() {
        let wide = layout(
            ReservedRegionArea(kind: .division, frame: CGRect(x: 0, y: 150, width: 900, height: 200), isActive: true))
        #expect(wide.badgeCorner(in: tile, side: side, inset: inset) == .bottomTrailing)
    }

    @Test func aRegionThatOnlyTouchesACornerLeavesThatCornerClear() {
        // The fold covers both bottom corners and ends exactly where the top-trailing badge ends; touching is clear,
        // so the badge takes the top-trailing corner instead of falling back to bottom-trailing.
        let fold = layout(division(CGRect(x: 0, y: 228, width: 900, height: 80)))
        #expect(fold.badgeCorner(in: tile, side: side, inset: inset) == .topTrailing)
    }

    @Test func aMovedBadgeStaysInsideTheVisibleBounds() {
        // A tile scrolled partly above the viewport with the measured iPhone Duo camera occlusion over its trailing
        // edge: the top-trailing corner is clear but above the viewport, so the badge takes the bottom-leading one.
        let scrolled = CGRect(x: 312, y: -35, width: 154, height: 154)
        let camera = ReservedRegionLayout(
            areas: [
                ReservedRegionArea(
                    kind: .occlusion, frame: CGRect(x: 382, y: 0, width: 84, height: 170), isActive: true)
            ],
            bounds: CGRect(x: 0, y: 0, width: 466, height: 678))
        #expect(camera.badgeCorner(in: scrolled, side: 22, inset: 7) == .bottomLeading)
    }

    @Test func aMovedBadgeLeavesTheTileLabelsVisible() {
        // A vertical fold over the trailing edge of a RAW video tile: the duration label uses the bottom-leading
        // corner and the RAW label the top-leading one, so no clear corner remains and the badge stays home.
        let fold = layout(division(CGRect(x: 170, y: 0, width: 40, height: 900)))
        let duration = CGRect(x: 105, y: 280, width: 60, height: 20)
        let raw = CGRect(x: 105, y: 205, width: 34, height: 20)
        #expect(fold.badgeCorner(in: tile, side: side, inset: inset, avoiding: [duration]) == .topLeading)
        #expect(fold.badgeCorner(in: tile, side: side, inset: inset, avoiding: [duration, raw]) == .bottomTrailing)
    }

    @Test func emptyFramesAreIgnored() {
        let empty = layout(ReservedRegionArea(kind: .occlusion, frame: .zero, isActive: true))
        #expect(empty.isEmpty)
    }
}
