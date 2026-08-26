// GridTransitionRendererInput.swift
//
// Adapts pure draw intent to the renderer's premultiplied source-over blend. A mixed slot draws the source as
// an opaque base and the target over it at `localProgress`, producing the full-slot linear mix without background
// bleed. Single-sided entries and exits retain their progress alpha. Draw order is far-to-near.

import CoreGraphics

package struct GridTransitionDraw: Equatable, Sendable {
    package let index: Int  // Flat identity index used for UID and texture lookup.
    package let rect: CGRect  // viewport-space
    package let alpha: Double  // 0…1
    package let componentID: Int
    package let isTarget: Bool  // source vs target occupant (diagnostics / ordering)
    package let localProgress: Double

    package init(
        index: Int,
        rect: CGRect,
        alpha: Double,
        componentID: Int,
        isTarget: Bool,
        localProgress: Double
    ) {
        self.index = index
        self.rect = rect
        self.alpha = alpha
        self.componentID = componentID
        self.isTarget = isTarget
        self.localProgress = localProgress
    }
}

package enum GridTransitionRendererInput {
    package static func draws(plan: GridTransitionPlan, at q: Double) -> [GridTransitionDraw] {
        var out: [GridTransitionDraw] = []
        for slot in plan.renderIntent(at: q) {
            switch slot.role {
            case .stable, .source, .target, .exit:
                if let id = slot.sourceIdentity {
                    out.append(
                        .init(
                            index: id, rect: slot.rect, alpha: 1, componentID: slot.componentID,
                            isTarget: false, localProgress: slot.localProgress))
                }
            case .entry:
                if let id = slot.targetIdentity {
                    out.append(
                        .init(
                            index: id, rect: slot.rect, alpha: 1, componentID: slot.componentID,
                            isTarget: true, localProgress: slot.localProgress))
                }
            case .dissolve:
                // Mixed slots draw an opaque source below the target to avoid background bleed.
                // Single-sided slots retain their alpha weight against the background.
                let mixed = slot.sourceIdentity != nil && slot.targetIdentity != nil
                if let s = slot.sourceIdentity {
                    out.append(
                        .init(
                            index: s, rect: slot.rect, alpha: mixed ? 1.0 : slot.sourceWeight,
                            componentID: slot.componentID, isTarget: false, localProgress: slot.localProgress))
                }
                if let t = slot.targetIdentity {
                    out.append(
                        .init(
                            index: t, rect: slot.rect, alpha: slot.targetWeight,
                            componentID: slot.componentID, isTarget: true, localProgress: slot.localProgress))
                }
            }
        }
        return out
    }
}
