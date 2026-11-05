import CoreGraphics
import GridCore
import Testing
import TimelineCore

@Suite struct GridDivisionGeometryTests {
    private let viewport = CGSize(width: 867, height: 669)

    private struct ComparableTransitionDraw: Equatable {
        let index: Int
        let rect: CGRect
        let isTarget: Bool
    }

    @Test(arguments: [CGFloat(867), 951])
    func verticalDivisionsUseTheOrdinaryFullWidthAtEveryZoomStep(width: CGFloat) throws {
        let size = CGSize(width: width, height: viewport.height)
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
        let ordinary = SquareTileGridEngine(sectionCounts: [3_000], profile: profile)
        let candidate = ordinary
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
}
