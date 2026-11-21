import Foundation

/// Which review list the Duplicates route shows instead of the duplicates, on every platform. A list shows while the
/// person opened it and groups are left, also while a later check runs. Once its last group left, it stays closed until
/// the person opens it again, also when a later scan or check lists groups again.
@MainActor
public struct ExactDuplicatesRoute {
    /// The list that the person opened, until they go back or its last group leaves.
    public private(set) var opened: ExactDuplicateReviewList?

    public init() {}

    /// `list` is shown.
    public func shows(_ list: ExactDuplicateReviewList, of model: ExactDuplicatesModel) -> Bool {
        opened == list && !model.reviewGroups(list).isEmpty
    }

    /// Merge All belongs to the duplicates, not to a review list.
    public func offersMergeAll(of model: ExactDuplicatesModel) -> Bool {
        !ExactDuplicateReviewList.allCases.contains { shows($0, of: model) }
    }

    /// The person opens `list` from its row. Nothing opens while the screen shows no row for it.
    public mutating func show(_ list: ExactDuplicateReviewList, of model: ExactDuplicatesModel) {
        opened = model.reviewRowTitle(list) == nil ? nil : list
    }

    /// The person goes back to the duplicates.
    public mutating func back() {
        opened = nil
    }

    /// Call when the listed groups change: once the last group of the opened list left, the list closes for good.
    public mutating func follow(_ model: ExactDuplicatesModel) {
        if let opened, model.reviewGroups(opened).isEmpty { self.opened = nil }
    }
}
