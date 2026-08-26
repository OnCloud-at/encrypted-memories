/// Pure favorite projection shared by every platform host.
///
/// Backends retain the transport and partial-failure contract. This policy only computes the optimistic
/// observable state and the exact rollback for failed identities.
public enum FavoriteMutationPolicy {
    /// A mixed selection becomes favorite. A selection that is entirely favorite becomes unfavorite.
    public static func target(
        for selection: Set<PhotoUID>,
        current: Set<PhotoUID>
    ) -> Bool? {
        guard !selection.isEmpty else { return nil }
        return !selection.allSatisfy(current.contains)
    }

    public static func requestedUIDs(
        selection: Set<PhotoUID>,
        current: Set<PhotoUID>,
        target: Bool
    ) -> Set<PhotoUID> {
        selection.filter { current.contains($0) != target }
    }

    public static func optimisticState(
        current: Set<PhotoUID>,
        requested: Set<PhotoUID>,
        target: Bool
    ) -> Set<PhotoUID> {
        var result = current
        if target {
            result.formUnion(requested)
        } else {
            result.subtract(requested)
        }
        return result
    }

    public static func rollbackState(
        current: Set<PhotoUID>,
        failed: Set<PhotoUID>,
        target: Bool
    ) -> Set<PhotoUID> {
        var result = current
        if target {
            result.subtract(failed)
        } else {
            result.formUnion(failed)
        }
        return result
    }

    /// Applies local mutations that started after an authoritative favorite read. This prevents a delayed
    /// response from replacing newer optimistic or completed writes while preserving every unaffected UID.
    public static func reconciling(
        authoritative: Set<PhotoUID>,
        newerTargets: [PhotoUID: Bool]
    ) -> Set<PhotoUID> {
        var result = authoritative
        for (uid, target) in newerTargets {
            if target {
                result.insert(uid)
            } else {
                result.remove(uid)
            }
        }
        return result
    }
}
