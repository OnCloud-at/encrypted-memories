import UploadCore

/// The sections of a backup problem list, in the order of `BackupIssueSection`.
public enum BackupProblemSection {
    public struct Group<Item>: Identifiable {
        public let id: BackupIssueSection
        public let items: [Item]
        public var title: String { id.localizedTitle }
    }

    public static func grouped<Item>(
        _ items: [Item], section: (Item) -> BackupIssueSection
    ) -> [Group<Item>] {
        BackupIssueSection.allCases.compactMap { category in
            let rows = items.filter { section($0) == category }
            return rows.isEmpty ? nil : Group(id: category, items: rows)
        }
    }

    /// Groups problem rows by the section of their outcome. A row's section can differ from its category's: a failed
    /// row that the next launch runs again keeps the category that Try again selects, but continues by itself.
    public static func grouped<Item>(_ items: [Item], item: (Item) -> BackupFailedItem) -> [Group<Item>] {
        grouped(items, section: { item($0).section })
    }
}
