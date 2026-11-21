import Foundation
import PhotosCore

/// A list of copies that the person compares in the viewer and moves to the trash there. No merge takes them, and they
/// add nothing to the counts or to the space that merging frees.
public enum ExactDuplicateReviewList: String, CaseIterable, Sendable, Hashable, Identifiable {
    /// Copies with the same bytes whose details differ.
    case differing
    /// Different files that are possibly the same photo.
    case possible

    public var id: String { rawValue }

    /// The title of the row that opens the list, and of the list.
    public var title: String {
        switch self {
        case .differing: L10n.string("duplicates.differing_title")
        case .possible: L10n.string("duplicates.possible_title")
        }
    }

    /// The explanation above the groups.
    public var message: String {
        switch self {
        case .differing: L10n.string("duplicates.differing_message")
        case .possible: L10n.string("duplicates.possible_message")
        }
    }

    /// The accessibility identifier of the row; the parts of the list append to it.
    public var identifier: String { "duplicates.\(rawValue)" }
}

/// One group of a review list: its copies and the details that are not equal for all of them.
public struct ExactDuplicateReviewGroup: Sendable, Equatable, Identifiable {
    /// The content hash of a differing group, or the ID of a possibly identical group.
    public let id: String
    public let members: [PhotoUID]
    /// The details that differ, in `ExactDuplicateDetail` order, without `livePhoto`; see `differences(with:)`.
    public let differences: [ExactDuplicateDetail]

    public init(id: String, members: [PhotoUID], differences: [ExactDuplicateDetail]) {
        self.id = id
        self.members = members
        self.differences = differences
    }

    /// `differences`, and `livePhoto` when `item` finds a Live Photo and a photo that is not one among the members. Live
    /// Photo is no detail of the fingerprint, so it never decides alone that copies differ.
    public func differences(with item: (PhotoUID) -> PhotoItem?) -> [ExactDuplicateDetail] {
        Set(members.compactMap { item($0)?.isLivePhoto }).count > 1 ? differences + [.livePhoto] : differences
    }
}
