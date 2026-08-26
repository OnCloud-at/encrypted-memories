import Foundation

/// Canonical section and snapshot views of the same timeline content.
///
/// Duplicate identities are removed once, preserving the first incoming occurrence. Hosts build this
/// value off-main and publish both views together so grid, search and indexed lookups cannot diverge.
public struct TimelineContentProjection: Sendable {
    public let sections: [TimelineSection]
    public let snapshot: TimelineSnapshot
    public let uids: [PhotoUID]

    public init(sections: [TimelineSection]) {
        var seen = Set<PhotoUID>()
        var normalized: [TimelineSection] = []
        normalized.reserveCapacity(sections.count)

        for section in sections {
            let items = section.items.filter { seen.insert($0.uid).inserted }
            guard !items.isEmpty else { continue }
            normalized.append(
                TimelineSection(
                    id: section.id,
                    date: section.date,
                    title: section.title,
                    items: items
                ))
        }

        self.sections = normalized
        let snapshot = TimelineSnapshot(sections: normalized)
        self.snapshot = snapshot
        uids = snapshot.items.map(\.uid)
    }

    public func removing(_ uids: Set<PhotoUID>) -> TimelineContentProjection {
        guard !uids.isEmpty else { return self }
        let filtered = sections.compactMap { section -> TimelineSection? in
            let items = section.items.filter { !uids.contains($0.uid) }
            guard !items.isEmpty else { return nil }
            return TimelineSection(id: section.id, date: section.date, title: section.title, items: items)
        }
        return TimelineContentProjection(sections: filtered)
    }

    /// Adds restored items back to the canonical production timeline. Existing identities remain authoritative;
    /// both published views use the same total order without requiring a platform-specific insertion path.
    public func inserting(_ items: [PhotoItem]) -> TimelineContentProjection {
        guard let first = items.first else { return self }
        let restored = TimelineSection(id: "restored", date: first.captureTime, title: "", items: items)
        let merged = TimelineSnapshot(sections: sections + [restored]).items
        let template = sections.first
        return TimelineContentProjection(sections: [
            TimelineSection(
                id: template?.id ?? "all",
                date: merged.first?.captureTime ?? first.captureTime,
                title: template?.title ?? "",
                items: merged
            )
        ])
    }
}
