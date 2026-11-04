import CoreGraphics
import GridCore
import MetalGridComposeCore
import Testing
import TimelineCore

@Suite struct GridDivisionGeometryTests {
    private let viewport = CGSize(width: 867, height: 669)
    private let division = CGRect(x: 455.116, y: 0, width: 40, height: 669)

    private struct ComparableTransitionDraw: Equatable {
        let index: Int
        let rect: CGRect
        let isTarget: Bool
    }

    private func engine(
        width: CGFloat = 867, count: Int = 3_000, fillOrder: GridFillOrder = .newestBottomTrailing
    )
        -> SquareTileGridEngine
    {
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
        var engine = SquareTileGridEngine(sectionCounts: [count], profile: profile, fillOrder: fillOrder)
        // Exercise the legacy core geometry directly until its separate removal; the composer no longer selects it.
        engine.divisionFrame = division
        return engine
    }

    private func isClear(_ rect: CGRect) -> Bool {
        rect.maxX <= division.minX || rect.minX >= division.maxX
    }

    @Test(arguments: [CGFloat(867), 951], [false, true])
    func verticalDivisionsUseTheOrdinaryFullWidthAtEveryZoomStep(width: CGFloat, isActive: Bool) throws {
        let size = CGSize(width: width, height: viewport.height)
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
        let ordinary = SquareTileGridEngine(sectionCounts: [3_000], profile: profile)
        var candidate = ordinary
        candidate.divisionFrame = MetalGridFrameComposer.gridDivisionFrame(
            areas: [ReservedRegionArea(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: isActive)],
            bounds: CGRect(origin: .zero, size: size), profile: profile)
        #expect(candidate.divisionFrame == nil)
        for level in 0..<candidate.levelCount {
            let plan = candidate.framePlan(level: level, viewportSize: size, scrollOffset: .zero, overscan: 0)
            #expect(plan == ordinary.framePlan(level: level, viewportSize: size, scrollOffset: .zero, overscan: 0))
            let row = plan.visibleSlots.filter { $0.row == 0 }.sorted { $0.column < $1.column }
            #expect(row.count == profile.levels[level].nominalColumns)
            let first = try #require(row.first)
            let last = try #require(row.last)
            #expect(first.slotRect.minX == 0)
            #expect(abs(last.slotRect.maxX - width) < 1e-9)
            for pair in zip(row, row.dropFirst()) {
                #expect(abs(pair.1.slotRect.minX - pair.0.slotRect.maxX - profile.levels[level].gap) < 1e-9)
            }
            for slot in plan.visibleSlots {
                let point = CGPoint(x: slot.slotRect.midX, y: slot.slotRect.midY)
                #expect(candidate.hitTest(contentPoint: point, level: level, width: width)?.index == slot.index)
                #expect(candidate.cursorColumn(viewportX: point.x, level: level, width: width) == slot.column)
                #expect(candidate.slotRect(flatIndex: slot.index, level: level, width: width) == slot.slotRect)
            }
        }

        let contentPoint = CGPoint(x: width / 2, y: 1_200)
        let viewportPoint = CGPoint(x: width / 2, y: 300)
        let actualZoom = try #require(
            candidate.beginZoomTransaction(
                cursorContentPoint: contentPoint, viewportPoint: viewportPoint, level: 1, width: width))
        let ordinaryZoom = try #require(
            ordinary.beginZoomTransaction(
                cursorContentPoint: contentPoint, viewportPoint: viewportPoint, level: 1, width: width))
        for step in 0...50 {
            let level = CGFloat(step) / 10
            #expect(
                actualZoom.frame(continuousLevel: level, viewportSize: size, overscan: 0)
                    == ordinaryZoom.frame(continuousLevel: level, viewportSize: size, overscan: 0))
        }
        func comparableDraws(_ controller: GridTransitionController) -> [ComparableTransitionDraw] {
            controller.currentDraws().map { draw in
                ComparableTransitionDraw(index: draw.index, rect: draw.rect, isTarget: draw.isTarget)
            }.sorted { lhs, rhs in
                // Compare end-state geometry within one zoom pair, independently of hash-backed draw ordering.
                let left = (
                    lhs.index, lhs.rect.minX, lhs.rect.minY, lhs.rect.width, lhs.rect.height, lhs.isTarget ? 1 : 0
                )
                let right = (
                    rhs.index, rhs.rect.minX, rhs.rect.minY, rhs.rect.width, rhs.rect.height, rhs.isTarget ? 1 : 0
                )
                return left < right
            }
        }
        var realPassed = true
        var controlPassed = true
        for level in 0..<(candidate.levelCount - 1) {
            let ordinarySource = ordinary.framePlan(
                level: level, viewportSize: size, scrollOffset: .zero, overscan: 100)
            let ordinaryTarget = ordinary.framePlan(
                level: level + 1, viewportSize: size, scrollOffset: .zero, overscan: 100)
            let actualTransition = GridTransitionController()
            let ordinaryTransition = GridTransitionController()
            let controlTransition = GridTransitionController()
            for (engine, controller) in [
                (candidate, actualTransition), (ordinary, ordinaryTransition), (ordinary, controlTransition),
            ] {
                let source = engine.framePlan(
                    level: level, viewportSize: size, scrollOffset: .zero, overscan: 100)
                let target = engine.framePlan(
                    level: level + 1, viewportSize: size, scrollOffset: .zero, overscan: 100)
                // Full input equality includes columns, square side, origins, gaps, viewport and every level slot.
                #expect(source == ordinarySource)
                #expect(target == ordinaryTarget)
                #expect(
                    controller.beginPinch(
                        source: source, target: target,
                        anchorIndex: 0, viewportSize: size, selection: []))
            }
            for progress in [0.0, 1] {
                actualTransition.setProgress(progress)
                ordinaryTransition.setProgress(progress)
                controlTransition.setProgress(progress)
                let actual = comparableDraws(actualTransition)
                let expected = comparableDraws(ordinaryTransition)
                let control = comparableDraws(controlTransition)
                realPassed = realPassed && actual == expected
                controlPassed = controlPassed && control == expected
                #expect(actual == expected)
                #expect(control == expected)
            }
        }
        print("DUO1125_TRANSITION_COMPARE width=\(width) real=\(realPassed) control=\(controlPassed)")
    }

    @Test func overzoomKeepsTheUnscaledAnchorColumnAcrossTheBoundaryCursors() throws {
        let engine = engine()
        var changedColumns = Set<Int>()
        var excessiveMotion = Set<Int>()
        var occupiedDivision = Set<Int>()
        var maximumForcedEscape: CGFloat = 0
        var maximumEscapeCursor = 0
        for cursor in Array(214...268) + [700] {
            let point = CGPoint(x: cursor, y: 300)
            let tx = try #require(
                engine.beginZoomTransaction(
                    cursorContentPoint: CGPoint(x: cursor, y: 1_200), viewportPoint: point,
                    level: 0, width: viewport.width))
            let sourceColumn = tx.frame(continuousLevel: 0, viewportSize: viewport, overscan: 0).anchorColumn
            var previous = try #require(
                tx.rect(forGlobalIndex: tx.anchorGlobalIndex, continuousLevel: 0, viewportSize: viewport))
            let original = previous
            let half = tx.levels[0].nominalColumns / 2
            let stepsFromInnerEdge = sourceColumn < half ? half - sourceColumn : sourceColumn - half
            let sideChange = tx.apparentSlotSide(at: 0, width: viewport.width) * 0.6 / 100
            let rounding = viewport.width.ulp * 64
            for step in 1...50 {
                let level = -CGFloat(step) / 100
                let frame = tx.frame(continuousLevel: level, viewportSize: viewport, overscan: 0)
                if frame.anchorColumn != sourceColumn { changedColumns.insert(cursor) }
                let rect = try #require(
                    tx.rect(forGlobalIndex: tx.anchorGlobalIndex, continuousLevel: level, viewportSize: viewport))
                if abs(rect.minX - previous.minX) > CGFloat(stepsFromInnerEdge) * sideChange + rounding
                    || abs(rect.minY - previous.minY) > tx.anchorLocalFraction.y * sideChange + rounding
                {
                    excessiveMotion.insert(cursor)
                }
                if !frame.visibleSlots.allSatisfy({ isClear($0.rect) }) { occupiedDivision.insert(cursor) }
                let forcedEscape: CGFloat
                if sourceColumn < half {
                    let outerEdge = division.minX - CGFloat(half - 1 - sourceColumn) * frame.pitch
                    forcedEscape = max(0, CGFloat(cursor) - outerEdge)
                } else {
                    let outerEdge = division.maxX + CGFloat(sourceColumn - half) * frame.pitch
                    forcedEscape = max(0, outerEdge - CGFloat(cursor))
                }
                let escape = max(0, max(rect.minX - CGFloat(cursor), CGFloat(cursor) - rect.maxX))
                #expect(abs(escape - forcedEscape) <= rounding)
                if escape > maximumForcedEscape {
                    maximumForcedEscape = escape
                    maximumEscapeCursor = cursor
                }
                if cursor == 700, step == 30 || step == 50 {
                    print("issue923 cursor700 level=\(level) anchor-left=\(rect.minX) forced-escape=\(escape)")
                }
                previous = rect
            }
            let restored = try #require(
                tx.rect(forGlobalIndex: tx.anchorGlobalIndex, continuousLevel: 0, viewportSize: viewport))
            #expect(restored == original, "spring-back restores the unscaled anchor rectangle")
            #expect(
                restored.minX <= CGFloat(cursor) + tx.levels[0].gap / 2
                    && restored.maxX >= CGFloat(cursor) - tx.levels[0].gap / 2)
        }
        #expect(changedColumns.isEmpty, "cursors whose source column changed: \(changedColumns.sorted())")
        #expect(excessiveMotion.isEmpty, "motion exceeds the derivative bound: \(excessiveMotion.sorted())")
        #expect(occupiedDivision.isEmpty, "rubber-band tiles enter the division: \(occupiedDivision.sorted())")
        #expect(maximumForcedEscape > 0)
        print(
            "issue923 overzoom maximum forced cursor escape=\(maximumForcedEscape) pt cursor=\(maximumEscapeCursor) levels0...-0.5"
        )
    }

    @Test func springBackRestoresCursorContainmentAtTheBaseDetent() throws {
        let engine = engine()
        for cursor: CGFloat in [250, 700] {
            let point = CGPoint(x: cursor, y: 300)
            let tx = try #require(
                engine.beginZoomTransaction(
                    cursorContentPoint: CGPoint(x: cursor, y: 1_200), viewportPoint: point, level: 0,
                    width: viewport.width))
            let before = try #require(
                tx.rect(forGlobalIndex: tx.anchorGlobalIndex, continuousLevel: 0, viewportSize: viewport))
            let stretched = try #require(
                tx.rect(forGlobalIndex: tx.anchorGlobalIndex, continuousLevel: -0.5, viewportSize: viewport))
            #expect(stretched.width > before.width)
            let restored = try #require(
                tx.rect(forGlobalIndex: tx.anchorGlobalIndex, continuousLevel: 0, viewportSize: viewport))
            #expect(restored == before)
            #expect(restored.contains(point))
            #expect(isClear(restored))
        }
    }

    @Test func theDividedAnchorMovesContinuouslyBetweenDetents() throws {
        let engine = engine()
        var largestJump: CGFloat = 0
        for cursor: CGFloat in [214, 230, 250, 265, 268, 600, 700] {
            let tx = try #require(
                engine.beginZoomTransaction(
                    cursorContentPoint: CGPoint(x: cursor, y: 1_200), viewportPoint: CGPoint(x: cursor, y: 300),
                    level: 0, width: viewport.width))
            var previous = try #require(
                tx.rect(forGlobalIndex: tx.anchorGlobalIndex, continuousLevel: 0, viewportSize: viewport))
            for step in 1...300 {
                let rect = try #require(
                    tx.rect(
                        forGlobalIndex: tx.anchorGlobalIndex, continuousLevel: CGFloat(step) / 100,
                        viewportSize: viewport))
                largestJump = max(largestJump, abs(rect.minX - previous.minX))
                #expect(rect.minX <= cursor + 1.5 && rect.maxX >= cursor - 1.5)
                #expect(isClear(rect))
                previous = rect
            }
        }
        #expect(largestJump < 5, "an intermediate level must not move the anchor by a whole column: \(largestJump)")
    }

    @Test func unusableDivisionsKeepTheWholeProfileOrdinary() {
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let plain = SquareTileGridEngine(sectionCounts: [3_000], profile: profile)
        for band in [
            CGRect(x: 20, y: 0, width: 40, height: 669),
            CGRect(x: 0.5, y: 0, width: 40, height: 669),
            CGRect(x: 455, y: 0, width: 0, height: 669),
        ] {
            #expect(
                MetalGridFrameComposer.gridDivisionFrame(
                    areas: [ReservedRegionArea(frame: band, isActive: true)],
                    bounds: CGRect(origin: .zero, size: viewport),
                    profile: profile) == nil)
            var candidate = plain
            candidate.divisionFrame = band
            for level in 0..<profile.levels.count {
                #expect(
                    candidate.framePlan(level: level, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
                        == plain.framePlan(level: level, viewportSize: viewport, scrollOffset: .zero, overscan: 0))
                #expect(
                    candidate.apparentSlotSide(at: CGFloat(level), width: viewport.width)
                        == plain.apparentSlotSide(at: CGFloat(level), width: viewport.width))
            }
        }
        let nearEdge = CGRect(x: 60, y: 0, width: 40, height: 669)
        #expect(
            MetalGridFrameComposer.gridDivisionFrame(
                areas: [ReservedRegionArea(frame: nearEdge, isActive: true)],
                bounds: CGRect(origin: .zero, size: viewport),
                profile: profile) == nil)
        var edge = plain
        edge.divisionFrame = nearEdge
        for level in 0..<profile.levels.count {
            let plan = edge.framePlan(level: level, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
            #expect(plan.columnGeometry.isDivided && plan.slotSide >= 1)
        }
        let invalidSide = GridColumnGeometry(
            columns: 6, gap: 3, width: viewport.width, division: division, targetSide: 0.5)
        #expect(!invalidSide.isDivided)
        #expect(invalidSide.side == SquareTileGridEngine.nominalSlotSide(columns: 6, gap: 3, width: viewport.width))
    }

    @Test func compactAndPointerProfilesKeepTheirCompleteOrdinaryGeometry() {
        let resolver = TimelineGridProfileConfiguration.production.resolver
        for affinity in [TimelineGridInputAffinity.touch, .pointer] {
            let width: CGFloat = affinity == .touch ? 402 : 867
            let profile = resolver.profile(for: TimelineGridViewport(layoutWidth: width, inputAffinity: affinity))
            let size = CGSize(width: width, height: 669)
            let plain = SquareTileGridEngine(sectionCounts: [3_000], profile: profile)
            var candidate = plain
            candidate.divisionFrame = CGRect(x: width / 2 - 20, y: 0, width: 40, height: 669)
            for level in 0..<profile.levels.count {
                #expect(
                    candidate.framePlan(level: level, viewportSize: size, scrollOffset: .zero, overscan: 0)
                        == plain.framePlan(level: level, viewportSize: size, scrollOffset: .zero, overscan: 0))
            }
        }
    }

    @Test func divisionFactsDoNotCreateColumnAlignment() {
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let bounds = CGRect(origin: .zero, size: viewport)
        let nearer = CGRect(x: 400, y: 0, width: 40, height: 669)
        let farther = CGRect(x: 200, y: 0, width: 40, height: 669)
        let invalid = [
            CGRect(x: 430, y: 300, width: 40, height: 20),
            CGRect(x: 430, y: 700, width: 40, height: 669),
            CGRect(x: 430, y: -700, width: 40, height: 669),
            CGRect(x: -200, y: 0, width: 100, height: 669),
            CGRect(x: 900, y: 0, width: 40, height: 669),
            CGRect(x: 433, y: 0, width: 0, height: 669),
        ]
        for frame in invalid {
            #expect(
                MetalGridFrameComposer.gridDivisionFrame(
                    areas: [ReservedRegionArea(frame: frame, isActive: true)], bounds: bounds, profile: profile) == nil
            )
        }
        for facts in [[farther, nearer], [nearer, farther]] + invalid.map({ [$0, farther] }) {
            #expect(
                MetalGridFrameComposer.gridDivisionFrame(
                    areas: facts.map { ReservedRegionArea(frame: $0, isActive: true) }, bounds: bounds,
                    profile: profile) == nil)
        }
    }

    @Test func deterministicDivisionSweepNeverRoundsIntoTheBandOrOutsideTheViewport() {
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        var seed: UInt64 = 0x923
        func sample() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return CGFloat(seed >> 11) / CGFloat(UInt64.max >> 11)
        }
        var overlaps = 0
        var outside = 0
        for _ in 0..<512 {
            let width = 821 + sample() * 800
            let band = CGRect(x: 100 + sample() * (width - 300), y: 0, width: 1 + sample() * 70, height: 669)
            for metrics in profile.levels {
                let geometry = GridColumnGeometry(
                    columns: metrics.nominalColumns, gap: metrics.gap, width: width, division: band)
                for column in 0..<geometry.columns {
                    let rect = CGRect(x: geometry.origin(of: column), y: 0, width: geometry.side, height: geometry.side)
                    if rect.maxX > band.minX && rect.minX < band.maxX { overlaps += 1 }
                    if rect.minX < 0 || rect.maxX > width { outside += 1 }
                }
            }
        }
        #expect(overlaps == 0, "strict edge overlaps: \(overlaps)")
        #expect(outside == 0, "settled columns outside the viewport: \(outside)")
    }

    @Test func dividedTransitionKeepsTheAnchorIdentityAtOneStableKey() throws {
        let engine = engine()
        let tx = try #require(
            engine.beginZoomTransaction(
                cursorContentPoint: CGPoint(x: 700, y: 1_200), viewportPoint: CGPoint(x: 700, y: 300), level: 1,
                width: viewport.width))
        func plan(_ level: Int) -> GridFramePlan {
            let detent = GridPinchDetentGeometry.cursorAlignedFrame(
                level: level, transaction: tx, engine: engine, width: viewport.width, viewportHeight: viewport.height)
            return engine.framePlan(
                level: level, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: detent.scrollY),
                overscan: 100, columnPhase: detent.phase)
        }
        let lattice = try #require(
            GridTransitionComponentBuilder.build(
                source: plan(1), target: plan(2), anchorIndex: tx.anchorGlobalIndex, viewportSize: viewport))
        let sourceKey = try #require(lattice.sourceOcc.first { $0.value == tx.anchorGlobalIndex }?.key)
        let targetKey = try #require(lattice.targetOcc.first { $0.value == tx.anchorGlobalIndex }?.key)
        #expect(sourceKey == targetKey)
        #expect(lattice.components.allSatisfy { !$0.keys.contains(sourceKey) })
        let controller = GridTransitionController()
        #expect(
            controller.beginPinch(
                source: plan(1), target: plan(2), anchorIndex: tx.anchorGlobalIndex,
                viewportSize: viewport, selection: []))
        for progress in [0.0, 0.25, 0.5, 0.75, 1] {
            controller.setProgress(progress)
            let anchorDraws = controller.currentDraws().filter { $0.index == tx.anchorGlobalIndex }
            #expect(anchorDraws.count == 1)
            #expect(anchorDraws.allSatisfy { $0.alpha == 1 && isClear($0.rect) })
        }
    }

    @Test(arguments: [false, true])
    func compactPointerAndHorizontalDivisionsKeepTheirExistingGeometry(isActive: Bool) {
        let resolver = TimelineGridProfileConfiguration.production.resolver
        let bounds = CGRect(origin: .zero, size: viewport)
        for profile in [
            resolver.profile(for: TimelineGridViewport(layoutWidth: 402, inputAffinity: .touch)),
            resolver.profile(for: TimelineGridViewport(layoutWidth: 867, inputAffinity: .pointer)),
        ] {
            #expect(
                MetalGridFrameComposer.gridDivisionFrame(
                    areas: [ReservedRegionArea(frame: division, isActive: isActive)], bounds: bounds, profile: profile)
                    == nil)
        }
        let profile = resolver.profile(for: TimelineGridViewport(layoutWidth: 867, inputAffinity: .touch))
        #expect(
            MetalGridFrameComposer.gridDivisionFrame(
                areas: [], bounds: bounds, profile: profile) == nil)
        #expect(
            MetalGridFrameComposer.gridDivisionFrame(
                areas: [ReservedRegionArea(frame: CGRect(x: 0, y: 300, width: 867, height: 40), isActive: isActive)],
                bounds: bounds, profile: profile) == nil)
        #expect(
            MetalGridFrameComposer.gridDivisionFrame(
                areas: [ReservedRegionArea(frame: division.offsetBy(dx: 84, dy: 0), isActive: true)],
                bounds: bounds.offsetBy(dx: 84, dy: 0), profile: profile) == nil)
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
            if level >= 0 {
                #expect(anchored.rect.minX <= cursorX + frame.gap / 2 && anchored.rect.maxX >= cursorX - frame.gap / 2)
            }
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

    @Test func legacyOffCentreDivisionKeepsEveryPhotoAndItsHitTargetClear() throws {
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        var engine = SquareTileGridEngine(sectionCounts: [3_000], profile: profile)
        engine.divisionFrame = division
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
