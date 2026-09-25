import Testing

@testable import GridCore

@Suite @MainActor struct GridUploadBadgeAnimatorTests {
    private func pieStep(_ frame: GridUploadBadgeFrame?) -> Int? {
        guard case .pie(let step)? = frame?.glyph else { return nil }
        return step
    }

    @Test func circleFillsSmoothlyInsteadOfJumping() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .waiting, now: 0)
        // The backup reports half the upload at once; the circle moves there frame by frame.
        var previous = 0
        var t = 0.3
        while t < 1.6 {
            let step = pieStep(animator.frame(for: 1, target: .uploading(step: 10), now: t)) ?? -1
            #expect(step >= previous, "the circle never empties while it fills")
            #expect(step - previous <= GridUploadBadgeGlyph.pieSteps / 8, "no visible jump at 120 Hz")
            previous = step
            t += 1.0 / 120
        }
        #expect(previous == GridUploadBadgeGlyph.pieSteps / 2)
        #expect(!animator.isAnimating([1], now: t))
    }

    @Test func backedUpPhotoFillsThenChecksThenFades() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .uploading(step: 4), now: 0)
        _ = animator.frame(for: 1, target: .uploading(step: 4), now: 1)

        // The backup is done and soon reports no badge at all; the grid still finishes the sequence.
        var sawFullCircle = false
        var sawDrawingCheck = false
        var sawFullCheck = false
        var sawFade = false
        var t = 1.0
        var ended: Double?
        while t < 5 {
            let target: GridUploadBadge? = t < 1.5 ? .done : nil
            let frame = animator.frame(for: 1, target: target, now: t)
            switch frame?.glyph {
            case .pie(GridUploadBadgeGlyph.pieSteps)?: sawFullCircle = true
            case .check(let step)? where step < GridUploadBadgeGlyph.checkSteps:
                #expect(sawFullCircle, "the checkmark draws only on the full circle")
                sawDrawingCheck = true
            case .check?:
                sawFullCheck = true
                if let alpha = frame?.alpha, alpha < 1 { sawFade = true }
            case nil:
                if ended == nil { ended = t }
            default:
                break
            }
            t += 1.0 / 60
        }
        #expect(sawFullCircle && sawDrawingCheck && sawFullCheck && sawFade)
        let end = try? #require(ended)
        #expect((end ?? 0) > 2, "the checkmark stays for a moment")
        #expect(!animator.isAnimating([1], now: 5))
    }

    @Test func abandonedUploadFadesOut() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .uploading(step: 10), now: 0)
        _ = animator.frame(for: 1, target: .uploading(step: 10), now: 1)
        let leaving = animator.frame(for: 1, target: nil, now: 1.1)
        #expect(leaving != nil, "the badge fades instead of vanishing")
        #expect(animator.frame(for: 1, target: nil, now: 2) == nil)
        #expect(animator.frame(for: 2, target: nil, now: 2) == nil, "a photo without a badge draws nothing")
    }

    @Test func fixedBadgeFadesInAndOut() {
        let animator = GridUploadBadgeAnimator<Int>()
        let first = animator.frame(for: 1, target: .attention, now: 0)
        #expect(first?.glyph == .attention)
        #expect(animator.isAnimating([1], now: 0.05), "the host keeps drawing while the badge fades in")
        #expect(animator.frame(for: 1, target: .attention, now: 1)?.alpha == 1)
        #expect(!animator.isAnimating([1], now: 1))
        let leaving = animator.frame(for: 1, target: nil, now: 2)
        #expect(leaving?.glyph == .attention, "the badge fades instead of vanishing")
        #expect(animator.isAnimating([1], now: 2))
        #expect(animator.frame(for: 1, target: nil, now: 3) == nil)
    }

    @Test func badgeThatReturnsWhileFadingContinuesFromItsOpacity() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .uploading(step: 10), now: 0)
        _ = animator.frame(for: 1, target: .uploading(step: 10), now: 1)
        _ = animator.frame(for: 1, target: nil, now: 1.2)
        let fading = animator.frame(for: 1, target: nil, now: 1.4)
        let back = animator.frame(for: 1, target: .uploading(step: 10), now: 1.4 + 1.0 / 120)
        let fadingAlpha = fading?.alpha ?? 0
        let backAlpha = back?.alpha ?? 0
        #expect(fadingAlpha < 1)
        #expect(abs(backAlpha - fadingAlpha) < 0.1, "no jump back to full opacity")
    }

    @Test func handoverKeepsTheAnimation() {
        let animator = GridUploadBadgeAnimator<Int>()
        _ = animator.frame(for: 1, target: .uploading(step: 20), now: 0)
        _ = animator.frame(for: 1, target: .uploading(step: 20), now: 2)
        animator.adopt(from: 1, to: 100)
        // The Proton photo continues where the pending tile was: full, no fade-in, no restart from empty.
        let frame = animator.frame(for: 100, target: .done, now: 2.01)
        #expect(frame?.alpha ?? 0 > 0.99)
        if case .pie(let step)? = frame?.glyph { #expect(step == GridUploadBadgeGlyph.pieSteps) }
    }

    @Test func staticGlyphMatchesTheBadge() {
        #expect(GridUploadBadgeGlyph(.waiting) == .pie(0))
        #expect(
            GridUploadBadgeGlyph(.uploading(step: GridUploadBadge.progressSteps)) == .pie(GridUploadBadgeGlyph.pieSteps)
        )
        #expect(GridUploadBadgeGlyph(.done) == .check(GridUploadBadgeGlyph.checkSteps))
        #expect(GridUploadBadgeGlyph(.notBackedUp).symbolName == "icloud.slash")
    }
}
