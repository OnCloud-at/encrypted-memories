import CoreGraphics
import GridCore
import MetalGridComposeCore
import Testing
import TimelineCore

@Suite struct GridDivisionGeometryTests {
    private let viewport = CGSize(width: 867, height: 669)
    private let division = CGRect(x: 455.116, y: 0, width: 40, height: 669)

    private func engine(
        width: CGFloat = 867, count: Int = 3_000, fillOrder: GridFillOrder = .newestBottomTrailing
    )
        -> SquareTileGridEngine
    {
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
        var engine = SquareTileGridEngine(sectionCounts: [count], profile: profile, fillOrder: fillOrder)
        engine.divisionFrame = MetalGridFrameComposer.gridDivisionFrame(
            areas: [ReservedRegionArea(frame: division, isActive: false)],
            bounds: CGRect(x: 0, y: 0, width: width, height: viewport.height), profile: profile)
        return engine
    }

    private func isClear(_ rect: CGRect) -> Bool {
        rect.maxX <= division.minX || rect.minX >= division.maxX
    }

    @Test func compactPointerAndHorizontalDivisionsKeepTheirExistingGeometry() {
        let resolver = TimelineGridProfileConfiguration.production.resolver
        let bounds = CGRect(origin: .zero, size: viewport)
        for profile in [
            resolver.profile(for: TimelineGridViewport(layoutWidth: 402, inputAffinity: .touch)),
            resolver.profile(for: TimelineGridViewport(layoutWidth: 867, inputAffinity: .pointer)),
        ] {
            #expect(
                MetalGridFrameComposer.gridDivisionFrame(
                    areas: [ReservedRegionArea(frame: division, isActive: true)], bounds: bounds, profile: profile)
                    == nil)
        }
        let profile = resolver.profile(for: TimelineGridViewport(layoutWidth: 867, inputAffinity: .touch))
        #expect(
            MetalGridFrameComposer.gridDivisionFrame(
                areas: [], bounds: bounds, profile: profile) == nil)
        #expect(
            MetalGridFrameComposer.gridDivisionFrame(
                areas: [ReservedRegionArea(frame: CGRect(x: 0, y: 300, width: 867, height: 40), isActive: true)],
                bounds: bounds, profile: profile) == nil)
        #expect(
            MetalGridFrameComposer.gridDivisionFrame(
                areas: [ReservedRegionArea(frame: division.offsetBy(dx: 84, dy: 0), isActive: false)],
                bounds: bounds.offsetBy(dx: 84, dy: 0), profile: profile) == division)
    }

    @Test func bothDenseOverviewLayersKeepTheirPhotosOutOfTheDivision() throws {
        let engine = engine()
        for source in [3, 4] {
            for pair in [(source, source + 1), (source + 1, source)] {
                let plan = try #require(
                    engine.overviewLayerDissolvePlan(
                        from: pair.0, to: pair.1, viewportSize: viewport, targetViewportSize: viewport,
                        sourceScrollY: 900, sourceColumnPhase: nil, preferredNormalMode: .squareFillCrop,
                        anchorContentPoint: CGPoint(x: 700, y: 1_200), anchorViewportPoint: CGPoint(x: 700, y: 300),
                        overscan: 100))
                for progress in [0.0, 0.25, 0.5, 0.75, 1] {
                    let frame = plan.withProgress(progress)
                    #expect(frame.source.visibleSlots.allSatisfy { isClear($0.viewportRect) })
                    #expect(frame.target.visibleSlots.allSatisfy { isClear($0.viewportRect) })
                    #expect(frame.source.columns == engine.metrics(level: pair.0).nominalColumns)
                    #expect(frame.target.columns == engine.metrics(level: pair.1).nominalColumns)
                }
            }
        }
    }

    @Test func everyWideStageKeepsSlotHitAndCursorGeometryTogether() {
        for width: CGFloat in [821, 867, 951, 1210] {
            for count in [17, 3_000] {
                for order in [GridFillOrder.topLeading, .newestBottomTrailing] {
                    let engine = engine(width: width, count: count, fillOrder: order)
                    for level in 0..<engine.levelCount {
                        for phase: Int? in [nil, 0, 3] {
                            let size = CGSize(width: width, height: viewport.height)
                            let plan = engine.framePlan(
                                level: level, viewportSize: size, scrollOffset: .zero, overscan: 100,
                                columnPhase: phase)
                            #expect(!plan.visibleSlots.isEmpty)
                            #expect(plan.visibleSlots.allSatisfy { isClear($0.viewportRect) })
                            #expect(Set(plan.visibleSlots.map(\.index)).count == plan.visibleSlots.count)
                            for slot in plan.visibleSlots {
                                let point = CGPoint(x: slot.slotRect.midX, y: slot.slotRect.midY)
                                #expect(
                                    engine.slotRect(
                                        flatIndex: slot.index, level: level, width: width, columnPhase: phase)
                                        == slot.slotRect)
                                #expect(
                                    engine.hitTest(contentPoint: point, level: level, width: width, columnPhase: phase)?
                                        .index == slot.index)
                                #expect(
                                    engine.cursorColumn(viewportX: point.x, level: level, width: width) == slot.column)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [CGFloat(180), 700])
    func aLivePinchAndItsCommitKeepTheDivisionEmpty(cursorX: CGFloat) throws {
        let engine = engine()
        let transaction = try #require(
            engine.beginZoomTransaction(
                cursorContentPoint: CGPoint(x: cursorX, y: 1_200), viewportPoint: CGPoint(x: cursorX, y: 300),
                level: 1, width: viewport.width))
        for level: CGFloat in [-0.3, 0, 0.25, 0.5, 0.75, 1, 1.5, 2, 2.5, 3, 4, 5] {
            let frame = transaction.frame(continuousLevel: level, viewportSize: viewport, overscan: 0)
            #expect(!frame.visibleSlots.isEmpty)
            #expect(frame.visibleSlots.allSatisfy { isClear($0.rect) }, "level \(level), cursor \(cursorX)")
            #expect(Set(frame.visibleSlots.map(\.index)).count == frame.visibleSlots.count)
            let anchored = try #require(frame.visibleSlots.first { $0.index == transaction.anchorGlobalIndex })
            #expect(abs(anchored.rect.minY + transaction.anchorLocalFraction.y * anchored.rect.height - 300) < 0.001)
            #expect(anchored.rect.minX <= cursorX + frame.gap / 2 && anchored.rect.maxX >= cursorX - frame.gap / 2)
        }
        for level in 0..<engine.levelCount {
            let detent = GridPinchDetentGeometry.cursorAlignedFrame(
                level: level, transaction: transaction, engine: engine, width: viewport.width,
                viewportHeight: viewport.height)
            for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                let slots = GridZoomCommitBridge.frame(
                    transaction: transaction, engine: engine, targetLevel: level, viewportSize: viewport,
                    scrollY: detent.scrollY, overscan: 0, progress: progress, columnPhase: detent.phase)
                #expect(!slots.isEmpty)
                #expect(slots.allSatisfy { isClear($0.rect) }, "commit \(level), progress \(progress)")
            }
        }
    }

    @Test(arguments: [CGFloat(180), 700])
    func aTransitionLatticeKeepsBothSidesOfTheDivisionClear(cursorX: CGFloat) throws {
        let engine = engine()
        let transaction = try #require(
            engine.beginZoomTransaction(
                cursorContentPoint: CGPoint(x: cursorX, y: 1_200), viewportPoint: CGPoint(x: cursorX, y: 300),
                level: 1, width: viewport.width))
        for source in 0..<3 {
            for pair in [(source, source + 1), (source + 1, source)] {
                func plan(_ level: Int) -> GridFramePlan {
                    let detent = GridPinchDetentGeometry.cursorAlignedFrame(
                        level: level, transaction: transaction, engine: engine, width: viewport.width,
                        viewportHeight: viewport.height)
                    return engine.framePlan(
                        level: level, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: detent.scrollY),
                        overscan: 100, columnPhase: detent.phase)
                }
                let controller = GridTransitionController()
                #expect(
                    controller.beginPinch(
                        source: plan(pair.0), target: plan(pair.1), anchorIndex: transaction.anchorGlobalIndex,
                        viewportSize: viewport, selection: []))
                for progress in [0.0, 0.25, 0.5, 0.75, 1] {
                    controller.setProgress(progress)
                    let draws = controller.currentDraws()
                    #expect(!draws.isEmpty)
                    #expect(draws.allSatisfy { isClear($0.rect) }, "\(pair) progress \(progress)")
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func anOffCentreDivisionKeepsEveryPhotoAndItsHitTargetClear(isActive: Bool) throws {
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        var engine = SquareTileGridEngine(sectionCounts: [3_000], profile: profile)
        engine.divisionFrame = MetalGridFrameComposer.gridDivisionFrame(
            areas: [ReservedRegionArea(frame: division, isActive: isActive)],
            bounds: CGRect(origin: .zero, size: viewport), profile: profile)
        let plan = engine.framePlan(
            level: profile.defaultLevel, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
        let row = plan.visibleSlots.filter { $0.row == 0 }
        #expect(plan.columns == 6)
        #expect(row.map(\.index) == Array(0..<6))
        #expect(row.allSatisfy { abs($0.slotRect.width - $0.slotRect.height) < 0.001 })
        #expect(row.allSatisfy { $0.slotRect.minX >= 0 && $0.slotRect.maxX <= viewport.width + 0.001 })
        #expect(row.filter { $0.slotRect.intersects(division) }.isEmpty)
        let left = try #require(row.map(\.slotRect.minX).min())
        let right = try #require(row.map(\.slotRect.maxX).max())
        #expect(abs((left + right) / 2 - division.midX) < 0.001)
        #expect(row.filter { $0.slotRect.minX >= division.maxX }.count == 3)
        for slot in row {
            let point = CGPoint(x: slot.slotRect.midX, y: slot.slotRect.midY)
            #expect(
                engine.hitTest(contentPoint: point, level: profile.defaultLevel, width: viewport.width)?.index
                    == slot.index)
        }
        #expect(
            engine.hitTest(
                contentPoint: CGPoint(x: division.midX, y: row[0].slotRect.midY),
                level: profile.defaultLevel, width: viewport.width) == nil)
    }
}
