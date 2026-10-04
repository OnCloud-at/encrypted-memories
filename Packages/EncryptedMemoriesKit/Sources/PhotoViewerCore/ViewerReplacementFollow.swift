import PhotosCore

/// Keeps an open viewer on a photo that the backup replaced while the viewer showed it.
///
/// An edit in Apple Photos replaces the earlier Proton photo: first with the pending tile of the edit, then with the
/// Proton photo that the upload made. The timeline publishes each step as `earlier -> replacing`. The viewer keeps
/// its own collection, so it swaps only the photos that left the timeline for their newest replacement, in the
/// same place. When the replacement already has its own page, the earlier page leaves instead, so no photo shows
/// twice. The open page stays on its photo or moves to that photo's replacement. A photo that left the timeline
/// without a replacement stays in the collection, as before.
public enum ViewerReplacementFollow {
    /// The longest replacement chain that one photo follows; a cycle also stops the walk.
    static let maxChainLength = 8

    public struct Followed {
        public let items: [PhotoItem]
        public let pages: ViewerPageIndex
        /// The page of the photo that the open page showed, or of its replacement.
        public let current: Int
        /// Photos that took a page in this step. A UID can return with new content, such as the tile of a second
        /// edit, so a viewer drops images that it kept for these photos from an earlier showing.
        public let arrived: [PhotoUID]
    }

    /// The collection with each replaced photo swapped for its newest replacement in `timeline`, or nil when no
    /// photo changed. The open page `current` swaps first, so it wins when two photos share one replacement.
    public static func follow(
        _ items: [PhotoItem],
        pages: ViewerPageIndex,
        current: Int,
        replacements: [PhotoUID: PhotoUID],
        timeline: TimelineSnapshot
    ) -> Followed? {
        guard !replacements.isEmpty else { return nil }
        let positions = replacements.keys.compactMap { earlier -> Int? in
            guard let position = pages.index(of: earlier), items.indices.contains(position),
                timeline.index(of: earlier) == nil
            else { return nil }
            return position
        }.sorted { ($0 == current ? -1 : $0) < ($1 == current ? -1 : $1) }
        var followed: [PhotoItem?] = items
        var currentUID = items.indices.contains(current) ? items[current].uid : nil
        var placed = Set<PhotoUID>()
        var arrived: [PhotoUID] = []
        var changed = false
        for position in positions {
            let earlier = items[position].uid
            guard let replacing = newestReplacement(of: earlier, replacements: replacements, timeline: timeline)
            else { continue }
            if pages.index(of: replacing.uid) == nil, placed.insert(replacing.uid).inserted {
                followed[position] = replacing
                arrived.append(replacing.uid)
            } else {
                // The replacement already has a page; the earlier page leaves so that no photo shows twice.
                followed[position] = nil
            }
            changed = true
            if earlier == currentUID { currentUID = replacing.uid }
        }
        guard changed else { return nil }
        let result = followed.compactMap { $0 }
        let resultPages = ViewerPageIndex(orderedUIDs: result.map(\.uid))
        let resultCurrent = currentUID.flatMap(resultPages.index(of:)) ?? min(max(current, 0), result.count - 1)
        return Followed(items: result, pages: resultPages, current: resultCurrent, arrived: arrived)
    }

    /// The last photo of the replacement chain that the timeline shows.
    private static func newestReplacement(
        of earlier: PhotoUID, replacements: [PhotoUID: PhotoUID], timeline: TimelineSnapshot
    ) -> PhotoItem? {
        var uid = earlier
        var visited: Set<PhotoUID> = [earlier]
        var newest: PhotoItem?
        for _ in 0..<maxChainLength {
            guard let next = replacements[uid], visited.insert(next).inserted else { break }
            uid = next
            if let item = timeline.item(for: next) { newest = item }
        }
        return newest
    }
}

extension ViewerReplacementFollow {
    /// The new index of a kept page's photo after a follow, or nil when the photo left. A follow moves a photo by at
    /// most the few pages that left before it, so the search starts near the old index, inside the new range.
    public static func newIndex(of uid: PhotoUID, near old: Int, count: Int, uidAt: (Int) -> PhotoUID) -> Int? {
        guard count > 0 else { return nil }
        let origin = min(max(old, 0), count - 1)
        for distance in 0..<count {
            let below = origin - distance
            let above = origin + distance
            if below >= 0, uidAt(below) == uid { return below }
            if distance > 0, above < count, uidAt(above) == uid { return above }
            if below < 0 && above >= count { break }
        }
        return nil
    }
}
