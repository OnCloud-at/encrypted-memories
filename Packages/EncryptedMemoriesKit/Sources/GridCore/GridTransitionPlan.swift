// GridTransitionPlan.swift
//
// Immutable per-direction transition plan + the pure per-frame draw-intent generator.
// One continuous geometry rect per lattice key, interpolated from source to target by smootherstep(q); the
// occupant handoff is a full-slot mix(sourceResolved, targetResolved, localProgress) carried as
// complementary source/target weights. localProgress is a pure function of the host-owned q, so
// reversing q reverses the whole presentation exactly. No clocks, no per-frame graph building.

import CoreGraphics

package enum GridTransitionKindTag: String, Sendable { case click, pinch }

package enum TransitionSlotRole: String, Sendable, Equatable {
    case stable  // same occupant both ends - drawn once
    case source  // mixed key, before window - source occupant
    case target  // mixed key, after window - target occupant
    case dissolve  // mixed or relocating key inside the window; source-to-target full-slot mix
    case entry  // target-only occupant arriving (no crossfade partner)
    case exit  // source-only occupant departing
}

/// Immutable per-frame draw intent for one lattice key at one canonical q.
package struct ResolvedTransitionSlot: Equatable, Sendable {
    package let key: RelativeSlotKey
    package let rect: CGRect  // continuous viewport rect at this q
    package let role: TransitionSlotRole
    package let sourceIdentity: Int?  // A missing source uses the background.
    package let targetIdentity: Int?  // A missing target uses the background.
    package let sourceWeight: Double  // 1-lp for dissolve; 1 for source/stable/exit; 0 for entry/target
    package let targetWeight: Double  // lp for dissolve; 1 for target/entry; 0 otherwise
    package let localProgress: Double  // crossfade progress within the component window (0…1)
    package let componentID: Int  // A negative value means no component.
}

package func gridTransitionSmootherstep(_ x: Double) -> Double {
    if x <= 0 { return 0 }
    if x >= 1 { return 1 }
    return x * x * x * (x * (x * 6 - 15) + 10)
}

package struct GridTransitionPlan: Sendable {
    package let kind: GridTransitionKindTag
    package let sourceLevel: Int
    package let targetLevel: Int
    package let durationMs: Double
    package let curve: LocalAlphaCurve

    package let components: [GridTransitionComponent]
    package let keys: [RelativeSlotKey]
    package let sourceOcc: [RelativeSlotKey: Int]  // flat index of source occupant
    package let targetOcc: [RelativeSlotKey: Int]
    package let sourceRect: [RelativeSlotKey: CGRect]  // actual viewport rect at q=0 (nil for entries)
    package let targetRect: [RelativeSlotKey: CGRect]  // actual viewport rect at q=1 (nil for exits)
    // Presentation geometry is filled for every key. Entries and exits use synthesized endpoints; identity
    // and role decisions continue to use the real occupants and frame rectangles.
    package let presentationSourceRect: [RelativeSlotKey: CGRect]
    package let presentationTargetRect: [RelativeSlotKey: CGRect]
    package let componentOfKey: [RelativeSlotKey: Int]
    package let windowOf: [Int: ClosedRange<Double>]  // Component ID to q-window.

    /// Geometry eases with smootherstep(q); the occupant crossfade is gated by the component window.
    package func geomProgress(_ q: Double) -> Double { gridTransitionSmootherstep(q) }

    /// Continuous spatial path for a key. Interpolate its presentation endpoints, which are defined
    /// for every key. Entries and exits use synthesized off-grid endpoints so they move with the grid.
    private func rect(for key: RelativeSlotKey, gp: Double) -> CGRect {
        let s = presentationSourceRect[key] ?? sourceRect[key] ?? targetRect[key] ?? .zero
        let t = presentationTargetRect[key] ?? targetRect[key] ?? sourceRect[key] ?? .zero
        return CGRect(
            x: s.minX + (t.minX - s.minX) * gp,
            y: s.minY + (t.minY - s.minY) * gp,
            width: s.width + (t.width - s.width) * gp,
            height: s.height + (t.height - s.height) * gp)
    }

    /// Pure per-frame draw intent at canonical progress q ∈ [0,1].
    package func renderIntent(at q: Double) -> [ResolvedTransitionSlot] {
        let gp = geomProgress(q)
        var out: [ResolvedTransitionSlot] = []
        out.reserveCapacity(keys.count)
        for key in keys {
            let r = rect(for: key, gp: gp)
            let s = sourceOcc[key]
            let t = targetOcc[key]
            let cid = componentOfKey[key] ?? -1
            let win = windowOf[cid]

            if let s, let t, s == t {
                out.append(
                    .init(
                        key: key, rect: r, role: .stable, sourceIdentity: s, targetIdentity: s,
                        sourceWeight: 1, targetWeight: 0, localProgress: 0, componentID: cid))
                continue
            }
            // mixed / relocating-common / entry / exit
            let lp: Double = {
                guard let win else { return q < (s != nil ? 1 : 0) ? 0 : 1 }
                return curve.localProgress(w0: win.lowerBound, w1: win.upperBound, q: q)
            }()

            if let s, let t {  // mixed key: source occupant and target occupant
                if lp <= 0 {
                    out.append(
                        .init(
                            key: key, rect: r, role: .source, sourceIdentity: s, targetIdentity: nil,
                            sourceWeight: 1, targetWeight: 0, localProgress: 0, componentID: cid))
                } else if lp >= 1 {
                    out.append(
                        .init(
                            key: key, rect: r, role: .target, sourceIdentity: t, targetIdentity: nil,
                            sourceWeight: 1, targetWeight: 0, localProgress: 1, componentID: cid))
                } else {
                    out.append(
                        .init(
                            key: key, rect: r, role: .dissolve, sourceIdentity: s, targetIdentity: t,
                            sourceWeight: 1 - lp, targetWeight: lp, localProgress: lp, componentID: cid))
                }
            } else if let s {  // source-only: relocating-common departs to background (or exit)
                if win != nil {
                    if lp <= 0 {
                        out.append(
                            .init(
                                key: key, rect: r, role: .source, sourceIdentity: s, targetIdentity: nil,
                                sourceWeight: 1, targetWeight: 0, localProgress: 0, componentID: cid))
                    } else if lp < 1 {
                        out.append(
                            .init(
                                key: key, rect: r, role: .dissolve, sourceIdentity: s, targetIdentity: nil,
                                sourceWeight: 1 - lp, targetWeight: lp, localProgress: lp, componentID: cid))
                    }  // A fully transparent item is not drawn.
                } else {
                    if gp >= 1 - 1e-9 { continue }  // The exit is absent from the settled target.
                    out.append(
                        .init(
                            key: key, rect: r, role: .exit, sourceIdentity: s, targetIdentity: nil,
                            sourceWeight: 1, targetWeight: 0, localProgress: 0, componentID: cid))
                }
            } else if let t {  // target-only: relocating-common arrives from background (or entry)
                if win != nil {
                    if lp >= 1 {
                        out.append(
                            .init(
                                key: key, rect: r, role: .target, sourceIdentity: t, targetIdentity: nil,
                                sourceWeight: 1, targetWeight: 0, localProgress: 1, componentID: cid))
                    } else if lp > 0 {
                        out.append(
                            .init(
                                key: key, rect: r, role: .dissolve, sourceIdentity: nil, targetIdentity: t,
                                sourceWeight: 1 - lp, targetWeight: lp, localProgress: lp, componentID: cid))
                    }  // A fully transparent item is not drawn.
                } else {
                    if gp <= 1e-9 { continue }  // The entry is absent from the settled source.
                    out.append(
                        .init(
                            key: key, rect: r, role: .entry, sourceIdentity: nil, targetIdentity: t,
                            sourceWeight: 0, targetWeight: 1, localProgress: 1, componentID: cid))
                }
            }
        }
        return out
    }

    /// Count of keys whose component is partially dissolving (0 < lp < 1) at this q.
    package func partialComponentCount(at q: Double) -> Int {
        var cids = Set<Int>()
        for (cid, win) in windowOf {
            let lp = curve.localProgress(w0: win.lowerBound, w1: win.upperBound, q: q)
            if lp > 1e-9 && lp < 1 - 1e-9 { cids.insert(cid) }
        }
        return cids.count
    }
}
