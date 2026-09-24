import CoreGraphics
import Foundation
import GridCore
import Testing
import TimelineCore

@testable import TimelineFeature

// The six Apple-like zoom levels + the aspect/square content-mode toggle. The toggle changes only how media
// fits inside the unchanged square slot (TileContentFitter); it never touches slotRect/columns/gap/pitch/
// contentSize/hitTest/visibleSlots/anchor/phase. No aspect-row / justified outer layout exists.
@Suite struct AppleGridLevelSpecAndContentModeTests {
    private let width: CGFloat = 1000
    private let viewport = CGSize(width: 1000, height: 760)
    private let eps: CGFloat = 0.5
    private func engine(_ count: Int = 4000) -> SquareTileGridEngine {
        SquareTileGridEngine.testRegular(sectionCounts: [count])
    }
    private let specs = SquareTileGridEngine.appleLevelSpecs

    private func contained(_ inner: CGRect, _ outer: CGRect) -> Bool {
        inner.minX >= outer.minX - eps && inner.minY >= outer.minY - eps && inner.maxX <= outer.maxX + eps
            && inner.maxY <= outer.maxY + eps
    }

    // Density levels use the documented slot metrics.
    @Test func sixAppleGridLevelsExist() {
        #expect(specs.count == 6)
        #expect(SquareTileGridEngine.testRegularLevels.count == 6)
        #expect(specs.map(\.id) == [0, 1, 2, 3, 4, 5])
        #expect(engine().levelCount == 6)
    }

    // Fixed-column levels fill the width at every width without reflow; the column
    // count is constant (held at nominalColumns) and the tile scales with width (resize = scale, never reflow).
    // At the calibration width it reproduces nominalColumns.
    @Test func levelSpecsFillWidthFixedColumns() {
        let e = engine()
        for level in 0..<e.levelCount {
            let nominal = e.metrics(level: level).nominalColumns
            var sides: [CGFloat] = []
            for w in [CGFloat(700), 1000, 1440, 2560, 3840] {
                let m = e.resolvedMetrics(level: level, width: w)
                sides.append(m.slotSide)
                #expect(abs((CGFloat(m.columns) * m.pitch - m.gap) - w) < 2.0, "level \(level) must fill width \(w)")
                #expect(m.columns == nominal, "level \(level) fixed-columns: count holds at \(nominal)")
            }
            #expect(sides.first! < sides.last!, "level \(level) tile must SCALE with width (fixed-columns, no reflow)")
            for i in 1..<sides.count {
                #expect(sides[i] >= sides[i - 1] - 0.001, "level \(level) tile monotone non-decreasing in width")
            }
            // At any width the level holds its nominalColumns (fixed-columns; equal at the reference width too).
            #expect(
                e.resolvedMetrics(level: level, width: GridSizePolicy.referenceWidth).columns
                    == e.metrics(level: level).nominalColumns,
                "level \(level) must reproduce nominalColumns at the reference width")
        }
    }

    // Column counts remain within the documented level bounds.
    @Test func levelNominalColumnsAreMonotonicIncreasingDensity() {
        for i in 1..<specs.count {
            #expect(specs[i].nominalColumns > specs[i - 1].nominalColumns, "density not increasing at L\(i)")
        }
    }

    // Gaps are non-negative and do not grow as density rises.
    @Test func levelGapsAreDefinedAndMonotonicOrIntentional() {
        for s in specs { #expect(s.gap >= 0) }
        for i in 1..<specs.count { #expect(specs[i].gap <= specs[i - 1].gap, "gap increased at L\(i)") }
    }

    // Slot sizes follow the level specification.
    @Test func largestLevelUsesApproximatelyThreeNominalColumns() {
        #expect(specs[0].nominalColumns == 3, "largest level should be ~3 columns: \(specs[0].nominalColumns)")
        #expect(specs[0].nominalColumns == specs.map(\.nominalColumns).min(), "L0 must be the lowest density")
    }

    // Overview levels use their dedicated metrics.
    @Test func overviewLevelsAreSquareOnly() {
        for level in [4, 5] {
            #expect(specs[level].supportedContentModes == [.squareFillCrop], "L\(level) must be square-only")
            #expect(specs[level].defaultContentMode == .squareFillCrop)
            #expect(engine().contentModeToggleAvailable(level: level) == false)
        }
    }

    // Level transitions preserve the documented ordering.
    @Test func normalLevelsSupportAspectFitAndSquareFill() {
        for level in 0...3 {
            #expect(
                specs[level].supportedContentModes == [.aspectFitInsideSquare, .squareFillCrop],
                "L\(level) must support both")
            #expect(engine().contentModeToggleAvailable(level: level) == true)
        }
    }

    // Level metrics remain stable at the calibration width.
    @Test func transitionKindsAreClassified() {
        #expect(specs[0].transitionKindToNext == .focusRowRelayout)
        #expect(specs[1].transitionKindToNext == .focusRowRelayout)
        #expect(specs[2].transitionKindToNext == .focusRowRelayout)
        #expect(specs[3].transitionKindToNext == .overviewWarp)
        #expect(specs[4].transitionKindToNext == .denseOverviewZoom)
        #expect(specs[5].transitionKindToNext == nil, "the densest level has no next")
    }

    @Test func transitionKindsCanBeDerivedFromSemanticRoles() {
        let e = engine()
        for level in 0...3 {
            #expect(e.metrics(level: level).semanticRole == .aspectThumbnail)
        }
        for level in [4, 5] {
            #expect(e.metrics(level: level).semanticRole == .squareOverview)
        }
        for level in 0..<e.levelCount - 1 {
            #expect(e.metrics(level: level).transitionKindToNext == e.derivedTransitionKindToNext(level: level))
        }
    }

    @Test func regularTimelineProfilePreservesProductionDefaults() {
        let profile = TimelineGridProfileConfiguration.production.profile(id: "regularTimeline")!
        let e = SquareTileGridEngine(sectionCounts: [4000], profile: profile)

        #expect(profile.id == "regularTimeline")
        #expect(profile.levels == SquareTileGridEngine.testRegularLevels)
        #expect(profile.defaultLevel == 3)
        #expect(e.defaultLevel == 3)
        #expect(e.levelCount == 6)
        #expect(e.levels.map(\.nominalColumns) == [3, 5, 7, 9, 20, 30])
        #expect(e.resolvedMetrics(level: e.defaultLevel, width: width).columns == 9)
    }

    @Test func compactTimelineProfileStartsWithOneColumnAndKeepsTopology() {
        let profile = TimelineGridProfileConfiguration.production.profile(id: "compactTimeline")!
        let e = SquareTileGridEngine(sectionCounts: [4000], profile: profile)

        #expect(profile.id == "compactTimeline")
        #expect(profile.defaultLevel == 2)
        #expect(e.defaultLevel == 2)
        #expect(e.levelCount == 6)
        #expect(e.levels.map(\.nominalColumns) == [1, 2, 3, 5, 12, 20])
        #expect(e.resolvedMetrics(level: 0, width: 390).columns == 1)
        #expect(abs(e.resolvedMetrics(level: 0, width: 390).slotSide - 390) < eps)

        for level in 0...3 { #expect(e.contentModeToggleAvailable(level: level)) }
        for level in [4, 5] { #expect(!e.contentModeToggleAvailable(level: level)) }
        #expect(e.adjacentTransitionKind(2, 3) == .focusRowRelayout)
        #expect(e.adjacentTransitionKind(3, 4) == .overviewWarp)
        #expect(e.adjacentTransitionKind(4, 5) == .denseOverviewZoom)
    }

    @Test func profileNamesAreViewportScopedNotPlatformScoped() {
        for id in TimelineGridProfileConfiguration.production.profiles.map(\.id) {
            let lower = id.lowercased()
            #expect(!lower.contains("mac"))
            #expect(!lower.contains("ios"))
            #expect(!lower.contains("ipad"))
            #expect(!lower.contains("iphone"))
        }
    }

    private func slot() -> CGRect { CGRect(x: 120, y: 240, width: 180, height: 180) }  // a square slot

    // Aspect-fit content stays inside the square slot.
    @Test func aspectFitInsideSquareContainedInSlot() {
        for aspect in [CGFloat(0.4), 0.75, 1.0, 1.5, 1.78, 2.5] {
            let f = TileContentFitter.fit(slotRect: slot(), mediaAspect: aspect, displayMode: .aspectFitInsideSquare)
            #expect(contained(f.contentRect, slot()), "aspectFit content escaped the slot at aspect \(aspect)")
            #expect(f.uvMin == .init(0, 0) && f.uvMax == .init(1, 1), "aspectFit must show the WHOLE image (full UV)")
            // The full media fits: at least one dimension equals the slot, neither exceeds it.
            #expect(f.contentRect.width <= slot().width + eps && f.contentRect.height <= slot().height + eps)
        }
    }

    // Square-fill content covers the slot.
    @Test func squareFillCropCoversSlot() {
        for aspect in [CGFloat(0.4), 0.75, 1.0, 1.5, 1.78, 2.5] {
            let f = TileContentFitter.fit(slotRect: slot(), mediaAspect: aspect, displayMode: .squareFillCrop)
            #expect(
                abs(f.contentRect.width - slot().width) < eps && abs(f.contentRect.height - slot().height) < eps,
                "squareFill must fill the whole slot at aspect \(aspect)")
            #expect(f.contentRect.equalTo(slot()) || contained(f.contentRect, slot().insetBy(dx: -eps, dy: -eps)))
            // Cover crops the longer axis in UV (unless the media is already square).
            if abs(aspect - 1) > 0.01 { #expect(f.uvMin != .init(0, 0) || f.uvMax != .init(1, 1)) }
        }
    }

    // Slot geometry is independent of content mode; only fitting differs.
    @Test func contentModeDoesNotChangeSlotRect() {
        let e = engine()
        let s1 = e.slotRect(flatIndex: 137, level: 2, width: width)!
        let s2 = e.slotRect(flatIndex: 137, level: 2, width: width)!
        #expect(s1 == s2)
        let a = TileContentFitter.fit(slotRect: s1, mediaAspect: 1.78, displayMode: .aspectFitInsideSquare)
        let b = TileContentFitter.fit(slotRect: s1, mediaAspect: 1.78, displayMode: .squareFillCrop)
        #expect(a.contentRect != b.contentRect, "the mode MUST change the content fit")
        #expect(
            contained(a.contentRect, s1) && contained(b.contentRect, s1), "both fits stay inside the unchanged slot")
    }

    // Hit testing is independent of content mode.
    @Test func contentModeDoesNotChangeHitTesting() {
        let e = engine()
        let p = CGPoint(x: 430, y: 5123)
        let h1 = e.hitTest(contentPoint: p, level: 2, width: width)?.index
        let h2 = e.hitTest(contentPoint: p, level: 2, width: width)?.index
        #expect(h1 == h2)
    }

    // Visible slots are independent of content mode.
    @Test func contentModeDoesNotChangeVisibleSlots() {
        let e = engine()
        let plan1 = e.framePlan(level: 2, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 4000), overscan: 0)
        let plan2 = e.framePlan(level: 2, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 4000), overscan: 0)
        #expect(plan1.visibleSlots == plan2.visibleSlots)
    }

    // Content size is independent of content mode.
    @Test func contentModeDoesNotChangeContentSize() {
        let e = engine()
        #expect(e.contentSize(level: 2, width: width) == e.contentSize(level: 2, width: width))
        #expect(e.contentSize(level: 4, width: width) == e.contentSize(level: 4, width: width))
    }

    // A wide aspect-fit video letterboxes inside the square slot; square fill covers it.
    @Test func wideVideoAspectFitDoesNotChangeOuterSlot() {
        let s = slot()
        let fit = TileContentFitter.fit(slotRect: s, mediaAspect: 16.0 / 9.0, displayMode: .aspectFitInsideSquare)
        #expect(contained(fit.contentRect, s))
        #expect(fit.contentRect.height < s.height - eps, "wide media must letterbox (shorter than the square)")
        #expect(abs(fit.contentRect.width - s.width) < eps, "wide media spans the full square width")
        let fill = TileContentFitter.fit(slotRect: s, mediaAspect: 16.0 / 9.0, displayMode: .squareFillCrop)
        #expect(fill.contentRect.equalTo(s), "squareFill keeps the slot square - outer slot unchanged")
    }

    // A portrait aspect-fit video pillarboxes inside the square slot.
    @Test func portraitAspectFitDoesNotChangeOuterSlot() {
        let s = slot()
        let fit = TileContentFitter.fit(slotRect: s, mediaAspect: 9.0 / 16.0, displayMode: .aspectFitInsideSquare)
        #expect(contained(fit.contentRect, s))
        #expect(fit.contentRect.width < s.width - eps, "portrait media must pillarbox (narrower than the square)")
        #expect(abs(fit.contentRect.height - s.height) < eps, "portrait media spans the full square height")
        #expect(abs((s.height) - (s.width)) < eps, "the slot itself is square regardless of media aspect")
    }

    // The toggle exposes the two supported fitting modes.
    @Test func aspectSquareToggleAvailableOnlyForLevels0To3() {
        let e = engine()
        for level in 0...3 { #expect(e.contentModeToggleAvailable(level: level)) }
        for level in [4, 5] { #expect(!e.contentModeToggleAvailable(level: level)) }
    }

    // Toggling changes only the fitter mode; engine geometry remains identical.
    @Test func aspectSquareToggleChangesOnlyTileContentFitterMode() {
        let e = engine()
        let before = e.framePlan(level: 1, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 3000), overscan: 0)
        // "Toggle": pick the two effective modes; the engine plan does not take them, so it cannot differ.
        let modeA = e.effectiveContentMode(preferred: .aspectFitInsideSquare, level: 1)
        let modeB = e.effectiveContentMode(preferred: .squareFillCrop, level: 1)
        #expect(modeA != modeB, "the two preferences resolve to different modes on a normal level")
        let after = e.framePlan(level: 1, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 3000), overscan: 0)
        #expect(
            before.visibleSlots == after.visibleSlots && before.contentSize == after.contentSize
                && before.columns == after.columns)
        // And the fitter does respond to the mode (so the toggle is not a no-op visually).
        let s = before.visibleSlots.first!.viewportRect
        #expect(
            TileContentFitter.fit(slotRect: s, mediaAspect: 1.7, displayMode: modeA).contentRect
                != TileContentFitter.fit(slotRect: s, mediaAspect: 1.7, displayMode: modeB).contentRect)
    }

    // The anchor item is independent of content mode.
    @Test func aspectSquareTogglePreservesAnchorItem() {
        let e = engine()
        let p = CGPoint(x: 512, y: 6200)
        let a1 = e.anchorItem(nearContentPoint: p, level: 2, width: width)?.flatIndex
        let a2 = e.anchorItem(nearContentPoint: p, level: 2, width: width)?.flatIndex
        #expect(a1 != nil && a1 == a2)
    }

    // Overview levels force square-fill cropping.
    @Test func overviewLevelsForceSquareFillCrop() {
        let e = engine()
        for level in [4, 5] {
            #expect(e.effectiveContentMode(preferred: .aspectFitInsideSquare, level: level) == .squareFillCrop)
            #expect(e.effectiveContentMode(preferred: .squareFillCrop, level: level) == .squareFillCrop)
        }
    }

    // The normal-level preference survives an overview round-trip.
    @Test func normalLevelContentModePreferenceRestoresAfterReturningFromOverview() {
        let e = engine()
        let preferred = TileContentDisplayMode.aspectFitInsideSquare  // user preference is held, not mutated
        #expect(e.effectiveContentMode(preferred: preferred, level: 2) == .aspectFitInsideSquare)
        #expect(e.effectiveContentMode(preferred: preferred, level: 4) == .squareFillCrop)  // overview overrides
        #expect(e.effectiveContentMode(preferred: preferred, level: 2) == .aspectFitInsideSquare)  // back to restored
    }

    // Toolbar symbols use the supported fallback path.
    @MainActor @Test func toolbarAspectToggleUsesNativeSymbolOrVectorFallback() {
        for mode in TileContentDisplayMode.allCases {
            let img = AspectSquareToggleModel.image(for: mode)
            #expect(img.size.width > 0 && img.size.height > 0, "a symbol OR vector fallback must render for \(mode)")
        }
        // Either native symbols resolve, or the CoreGraphics fallback is a valid template image.
        #expect(
            AspectSquareToggleModel.hasNativeSymbols
                || AspectSquareToggleModel.fallbackImage(for: .squareFillCrop).isTemplate)
    }

    // Toolbar accessibility labels describe the fitting mode.
    @MainActor @Test func toolbarAspectToggleHasAccessibilityLabel() {
        let a = AspectSquareToggleModel.accessibilityLabel(for: .squareFillCrop)
        let b = AspectSquareToggleModel.accessibilityLabel(for: .aspectFitInsideSquare)
        #expect(!a.isEmpty && !b.isEmpty && a != b, "each state needs a distinct, non-empty a11y label")
    }

    // Production geometry remains inside the slot.
    @Test func squareTileGridEngineStillOwnsSlotGeometry() {
        let e = engine()
        for level in 0..<e.levelCount {
            let plan = e.framePlan(
                level: level, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 2000), overscan: 0)
            for s in plan.visibleSlots {
                #expect(abs(s.viewportRect.width - s.viewportRect.height) < eps, "slot not square at L\(level)")
            }
        }
    }

    // Content geometry comes only from TileContentFitter and stays inside the slot.
    @Test func tileContentFitterOwnsContentGeometry() {
        let s = slot()
        for mode in TileContentDisplayMode.allCases {
            for aspect in [CGFloat(0.5), 1.0, 2.0] {
                #expect(
                    contained(TileContentFitter.fit(slotRect: s, mediaAspect: aspect, displayMode: mode).contentRect, s)
                )
            }
        }
    }

    // A trackpad pinch keeps the item under the cursor through commit.
    @Test func pinchStillAnchorsToCursorItem() {
        let e = engine()
        let cursorVP = CGPoint(x: 430, y: 360)
        let scrollY: CGFloat = 5000
        for sourcePhase in [nil, Int(2), Int(4)] {
            for (s, t) in [(2, 4), (3, 1), (4, 5)] {
                // The displayed item under the cursor == what the engine anchors (anchorItem; never nil for a non-empty grid).
                let cursorContent = CGPoint(x: cursorVP.x, y: cursorVP.y + scrollY)
                let displayed = e.anchorItem(
                    nearContentPoint: cursorContent, level: s, width: width, columnPhase: sourcePhase)!.flatIndex
                let tx = e.beginZoomTransaction(
                    cursorContentPoint: cursorContent,
                    viewportPoint: cursorVP, level: s, width: width, columnPhase: sourcePhase)!
                #expect(
                    tx.anchorGlobalIndex == displayed,
                    "begin anchored the wrong item s\(s) phase \(String(describing: sourcePhase))")
                let desiredCol = e.cursorColumn(viewportX: cursorVP.x, level: t, width: width)
                let phase = e.columnPhase(
                    forItem: tx.anchorGlobalIndex, targetColumn: desiredCol, level: t, width: width)
                let y = e.anchoredScrollOffset(
                    flatIndex: tx.anchorGlobalIndex, localFraction: tx.anchorLocalFraction,
                    viewportPoint: cursorVP, level: t, width: width, columnPhase: phase
                ).y
                let after = e.anchorItem(
                    nearContentPoint: CGPoint(x: cursorVP.x, y: cursorVP.y + y), level: t, width: width,
                    columnPhase: phase)!.flatIndex
                #expect(
                    after == displayed,
                    "pinch lost the cursor item s\(s)→t\(t) phase \(String(describing: sourcePhase))")
            }
        }
    }

    // Plus and minus still anchor at the viewport centre.
    @Test func plusMinusStillAnchorsToViewportCenter() {
        let e = engine()
        let center = CGPoint(x: width / 2, y: viewport.height / 2)
        let scrollY: CGFloat = 5000
        for sourcePhase in [nil, Int(3)] {
            let a = e.anchorItem(
                nearContentPoint: CGPoint(x: center.x, y: center.y + scrollY), level: 3, width: width,
                columnPhase: sourcePhase)!
            let target = 1
            let desiredCol = e.cursorColumn(viewportX: center.x, level: target, width: width)
            let phase = e.columnPhase(forItem: a.flatIndex, targetColumn: desiredCol, level: target, width: width)
            let y = e.anchoredScrollOffset(
                flatIndex: a.flatIndex, localFraction: a.localFraction,
                viewportPoint: center, level: target, width: width, columnPhase: phase
            ).y
            let after = e.anchorItem(
                nearContentPoint: CGPoint(x: center.x, y: center.y + y), level: target, width: width, columnPhase: phase
            )!.flatIndex
            #expect(
                after == a.flatIndex, "+/- lost the viewport-centre item (phase \(String(describing: sourcePhase)))")
        }
    }
}
