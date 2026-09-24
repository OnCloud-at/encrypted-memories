/// One optimistic favorite write, planned from the host's current favorite state.
public struct FavoriteMutationRequest: Sendable, Equatable {
    /// Identities whose favorite state changes. Never empty.
    public let requested: Set<PhotoUID>
    /// `true` adds the favorite tag, `false` removes it.
    public let target: Bool
    /// The favorite set to publish before the backend write completes.
    public let optimisticState: Set<PhotoUID>
}

/// Pure favorite projection shared by every platform host.
///
/// Backends retain the transport and partial-failure contract. This policy only computes the optimistic
/// observable state and the exact rollback for failed identities.
public enum FavoriteMutationPolicy {
    /// Plans a toggle for `selection`. Returns `nil` when the selection overlaps a mutation in flight, is empty,
    /// or needs no change, so a stale rollback can never overwrite a newer optimistic state.
    public static func request(
        selection: Set<PhotoUID>,
        current: Set<PhotoUID>,
        inFlight: Set<PhotoUID>
    ) -> FavoriteMutationRequest? {
        guard inFlight.isDisjoint(with: selection) else { return nil }
        guard let target = target(for: selection, current: current) else { return nil }
        let requested = requestedUIDs(selection: selection, current: current, target: target)
        guard !requested.isEmpty else { return nil }
        return FavoriteMutationRequest(
            requested: requested,
            target: target,
            optimisticState: optimisticState(current: current, requested: requested, target: target)
        )
    }

    /// Identities to roll back after a failed write. A partial failure reports its own failed identities; any
    /// other error fails the whole request.
    public static func failedUIDs(after error: any Error, requested: Set<PhotoUID>) -> Set<PhotoUID> {
        (error as? FavoriteMutationError)?.failed ?? requested
    }

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
