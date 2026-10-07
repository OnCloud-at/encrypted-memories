import Observation
import UploadCore

/// Shared in-memory rows for the native backup sheets. Album sheets supply their live rows directly.
@MainActor
@Observable
public final class BackupProblemListModel {
    public private(set) var items: [BackupFailedItem] = []

    public init() {}

    public var sections: [BackupProblemSection] { BackupProblemSection.group(items) }

    public func replaceItems(_ items: [BackupFailedItem]) {
        self.items = items
    }

    public func dismissItem(id: String) {
        items.removeAll { $0.id == id }
    }

    /// A resolved decision leaves immediately; a failed decision remains available for another action.
    public func refresh(
        afterDecision item: BackupFailedItem? = nil,
        read: () async -> [BackupFailedItem]
    ) async {
        let current = await read()
        items = current.filter { $0.id != item?.id || $0.issue == .deletedElsewhere }
    }
}

public struct BackupProblemSection: Identifiable {
    public let id: BackupIssueSection
    public let items: [BackupFailedItem]
    public var title: String { id.localizedTitle }

    public static func group(_ items: [BackupFailedItem]) -> [Self] {
        BackupIssueSection.allCases.compactMap { section in
            let rows = items.filter { $0.category.section == section }
            return rows.isEmpty ? nil : Self(id: section, items: rows)
        }
    }
}
