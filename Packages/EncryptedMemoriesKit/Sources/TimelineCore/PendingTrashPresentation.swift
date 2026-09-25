import Foundation
import GridCore
import PhotosCore

/// "Zuletzt gelöscht" as grids show it: the Proton trash plus local photos that were deleted before they
/// uploaded. Shared by iOS, iPadOS and macOS.
public struct PendingTrashPresentation: Sendable {
    /// Local photos in the trash list, newest capture first.
    public let items: [PhotoItem]
    /// A "Nicht gesichert" badge on each of them; opaque outside the package.
    public let badges: PendingUploadBadges
    public var localUIDs: Set<PhotoUID> { Set(items.map(\.uid)) }

    public init(items: [PhotoItem]) {
        self.items = items.sorted { TimelineOrder.areInIncreasingOrder($1, $0) }
        badges = PendingUploadBadges(base: Dictionary(uniqueKeysWithValues: items.map { ($0.uid, .notBackedUp) }))
    }

    public static let empty = PendingTrashPresentation(items: [])

    public var isEmpty: Bool { items.isEmpty }

    /// Inserts the local photos into Proton trash items that are newest first.
    public func merged(intoNewestFirst remote: [PhotoItem]) -> [PhotoItem] {
        guard !items.isEmpty else { return remote }
        var result: [PhotoItem] = []
        result.reserveCapacity(remote.count + items.count)
        var next = 0
        for item in remote {
            while next < items.count, TimelineOrder.areInIncreasingOrder(item, items[next]) {
                result.append(items[next])
                next += 1
            }
            result.append(item)
        }
        result.append(contentsOf: items[next...])
        return result
    }
}
