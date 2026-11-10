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
}
