import Foundation

/// Whether the Duplicates route shows the copies whose details differ instead of the duplicates, on every platform.
/// The list shows while the person opened it and groups are left, also while a later check runs. Once its last group
/// left, it stays closed until the person opens it again, also when a later scan lists differing copies again.
@MainActor
public struct ExactDuplicatesRoute {
    private var opensDiffering = false

    public init() {}

    /// The list of differing copies is shown.
    public func showsDiffering(of model: ExactDuplicatesModel) -> Bool {
        opensDiffering && !model.differingGroups.isEmpty
    }

    /// Merge All belongs to the duplicates, not to the differing copies.
    public func offersMergeAll(of model: ExactDuplicatesModel) -> Bool {
        !showsDiffering(of: model)
    }

    /// The person opens the list from its row. Nothing opens while the screen shows no row.
    public mutating func showDiffering(of model: ExactDuplicatesModel) {
        opensDiffering = model.differingRowTitle != nil
    }

    /// The person goes back to the duplicates.
    public mutating func back() {
        opensDiffering = false
    }

    /// Call when the listed groups change: once the last group left, the list closes for good.
    public mutating func follow(_ model: ExactDuplicatesModel) {
        if model.differingGroups.isEmpty { opensDiffering = false }
    }
}
