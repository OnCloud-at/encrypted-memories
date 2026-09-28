/// Keeps the grid density through round trips between grid profiles.
///
/// Folding and unfolding iPhone Duo, rotating it, or resizing a window can switch the grid profile (compact and
/// regular ladders). Each switch picks the target level whose tiles look closest in size, but the widths differ on
/// the way out and back, so a round trip could end one density step away from where it started. The memory returns
/// to the level each profile last showed, as long as the person did not zoom since the grid arrived in the profile
/// it leaves; a zoom makes the size match decide again.
public struct GridProfileLevelMemory: Sendable {
    private var levels: [String: Int] = [:]
    private var arrival: (profileID: String, level: Int)?

    public init() {}

    /// The level for `targetProfileID` after the grid leaves `sourceProfileID` at `sourceLevel`. `closestVisualLevel`
    /// runs only when the memory has no level for the target profile.
    public mutating func level(
        leaving sourceProfileID: String, at sourceLevel: Int, entering targetProfileID: String,
        closestVisualLevel: () -> Int
    ) -> Int {
        if let arrival, arrival.profileID != sourceProfileID || arrival.level != sourceLevel {
            levels.removeAll()
        }
        levels[sourceProfileID] = sourceLevel
        let target = levels[targetProfileID] ?? closestVisualLevel()
        arrival = (targetProfileID, target)
        return target
    }

    /// Forgets every level, for example when the caller sets a level or a profile explicitly.
    public mutating func reset() {
        levels.removeAll()
        arrival = nil
    }
}
