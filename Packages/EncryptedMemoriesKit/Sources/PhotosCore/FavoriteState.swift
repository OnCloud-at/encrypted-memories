/// The favorite state of one library host: the server favorites, the writes in flight, and whether a read is known.
///
/// Every host keeps one value and runs the backend calls itself. This type owns the transitions, so an optimistic
/// write, its rollback, and a server read that overlaps a write behave the same on every platform.
public struct FavoriteState: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        /// No server read has finished since the last reset.
        case loading
        case available
        /// The last server read failed.
        case unavailable
    }

    public private(set) var favorites: Set<PhotoUID> = []
    /// Identities with a write in flight. A new write that overlaps them is refused.
    public private(set) var inFlight: Set<PhotoUID> = []
    public private(set) var availability: Availability = .loading
    /// Writes that started while a server read ran or no read was known. The next read applies them, so a
    /// delayed response cannot undo a newer optimistic or completed write.
    private var newerTargets: [PhotoUID: Bool] = [:]
    private var isReading = false

    private var tracksNewerWrites: Bool { isReading || availability != .available }

    public init() {}

    /// Forgets the writes in flight and the read state, for a new session or a retry. The shown favorites stay
    /// when `keepingFavorites` is true, so a retry does not blank the hearts.
    public mutating func reset(keepingFavorites: Bool) {
        let shown = favorites
        self = FavoriteState()
        if keepingFavorites { favorites = shown }
    }

    /// Starts a server read. The writes in flight win over its result. Known favorites stay available meanwhile.
    public mutating func beginLoad() {
        for uid in inFlight { newerTargets[uid] = favorites.contains(uid) }
        isReading = true
        if availability != .available { availability = .loading }
    }

    /// Ends a server read. `nil` means that the read failed: the shown favorites stay, and favorites that were
    /// known before stay available.
    public mutating func finishLoad(_ loaded: Set<PhotoUID>?) {
        if let loaded {
            favorites = FavoriteMutationPolicy.reconciling(authoritative: loaded, newerTargets: newerTargets)
            availability = .available
        } else if availability != .available {
            availability = .unavailable
        }
        newerTargets.removeAll(keepingCapacity: false)
        isReading = false
    }

    /// Plans a write for `selection` and publishes its optimistic state. Nil when the write overlaps one in
    /// flight or changes nothing.
    public mutating func beginWrite(selection: Set<PhotoUID>, target: Bool) -> FavoriteMutationRequest? {
        guard
            let request = FavoriteMutationPolicy.request(
                selection: selection, current: favorites, inFlight: inFlight, target: target)
        else { return nil }
        if tracksNewerWrites {
            for uid in request.requested { newerTargets[uid] = request.target }
        }
        inFlight.formUnion(request.requested)
        favorites = request.optimisticState
        return request
    }

    /// Ends a write. The failed identities return to their state before the write.
    public mutating func finishWrite(_ request: FavoriteMutationRequest, failed: Set<PhotoUID>) {
        if tracksNewerWrites {
            for uid in failed { newerTargets.removeValue(forKey: uid) }
        }
        favorites = FavoriteMutationPolicy.rollbackState(current: favorites, failed: failed, target: request.target)
        inFlight.subtract(request.requested)
    }

    /// Runs a planned write through `write` and returns the identities that failed.
    public static func perform(
        _ request: FavoriteMutationRequest,
        write: ([PhotoUID], Bool) async throws -> Void
    ) async -> Set<PhotoUID> {
        do {
            try await write(Array(request.requested), request.target)
            return []
        } catch {
            return FavoriteMutationPolicy.failedUIDs(after: error, requested: request.requested)
        }
    }
}
