// GridTransitionSelectionEligibility.swift
//
// Selection decorations are absent from transition draws, so selection does not affect geometry eligibility.

package enum GridTransitionSelectionEligibility {
    /// Keeps the controller's eligibility decision explicit.
    package static func isEligible(selection: Set<Int>, relocatingIdentities: Set<Int>) -> Bool {
        _ = selection
        _ = relocatingIdentities
        return true
    }

    /// `relocatingIdentities` are the flat indices that change relative key between source and target.
    /// Derive the set of relocating identities from a built lattice.
    package static func relocatingIdentities(in lattice: GridTransitionLattice) -> Set<Int> {
        var srcKeyOf: [Int: RelativeSlotKey] = [:]
        var tgtKeyOf: [Int: RelativeSlotKey] = [:]
        for (k, id) in lattice.sourceOcc { srcKeyOf[id] = k }
        for (k, id) in lattice.targetOcc { tgtKeyOf[id] = k }
        var out: Set<Int> = []
        for id in Set(srcKeyOf.keys).intersection(tgtKeyOf.keys) where srcKeyOf[id] != tgtKeyOf[id] { out.insert(id) }
        return out
    }
}
