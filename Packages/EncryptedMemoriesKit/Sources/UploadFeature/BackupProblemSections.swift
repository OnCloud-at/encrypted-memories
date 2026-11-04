import DesignSystemCore
import PhotosCore
import SwiftUI
import UploadCore

/// Shared sections inside each platform's native List. The host supplies native row actions.
public struct BackupProblemSections<Row: View>: View {
    private struct IdentifiedProblem: Identifiable {
        let id: BackupProblemSnapshot.Row.ID
        let item: BackupFailedItem
    }
    private let rows: [IdentifiedProblem]
    private let row: (BackupFailedItem) -> Row

    public init(items: [BackupFailedItem], @ViewBuilder row: @escaping (BackupFailedItem) -> Row) {
        rows = items.map { IdentifiedProblem(id: .item($0.id), item: $0) }
        self.row = row
    }

    public init(rows: [BackupProblemSnapshot.Row], @ViewBuilder row: @escaping (BackupFailedItem) -> Row) {
        self.rows = rows.map { IdentifiedProblem(id: $0.id, item: $0.item) }
        self.row = row
    }

    public var body: some View {
        ForEach(BackupProblemSection.grouped(rows, section: { $0.item.category.section })) { section in
            Section {
                ForEach(section.items) { item in row(item.item) }
            } header: {
                Text(section.title)
                    .accessibilityIdentifier("backup.issueSection.\(section.id.rawValue)")
            }
        }
    }
}

/// The native hosts place this one action area outside their scrolling photo rows.
public struct BackupProblemActionArea: View {
    private let message: String?

    public init(message: String?) { self.message = message }

    public var body: some View {
        if let message {
            Text(message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("albumsync.restoreError")
        }
    }
}

/// The same file, reason, and retry caption with the existing native typography on each platform.
public struct BackupProblemRow<Actions: View>: View {
    private let item: BackupFailedItem
    private let actions: Actions
    private let previews: BackupProblemPreviewModel?

    public init(
        item: BackupFailedItem, previews: BackupProblemPreviewModel? = nil, @ViewBuilder actions: () -> Actions
    ) {
        self.item = item
        self.actions = actions()
        self.previews = previews
    }

    public var body: some View {
        HStack(alignment: .top, spacing: rowSpacing) {
            LocalPhotoThumbnail(
                uid: previews == nil ? nil : BackupProblemPreviewModel.uid(for: item.source),
                reloadID: previews.map(ObjectIdentifier.init)
            ) { uid in
                await previews?.thumbnail(for: uid)
            }
            Image(systemName: item.category.symbolName)
                .foregroundStyle(item.isPermanent ? detailColor : .orange)
                #if os(iOS)
                    .font(.body)
                #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    #if os(iOS)
                        .font(.subheadline)
                    #endif
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let retryDescription = item.retryDescription {
                    Text(retryDescription)
                        .font(.caption2)
                        .foregroundStyle(detailColor)
                }
            }
            #if os(macOS)
                Spacer(minLength: 8)
            #endif
            actions
        }
        .padding(.vertical, 2)
    }

    private var rowSpacing: CGFloat {
        #if os(macOS)
            10
        #else
            12
        #endif
    }

    private var detailColor: Color {
        #if os(macOS)
            .secondary
        #else
            ProtonColor.textWeak
        #endif
    }
}

extension BackupProblemRow where Actions == EmptyView {
    public init(item: BackupFailedItem, previews: BackupProblemPreviewModel? = nil) {
        self.init(item: item, previews: previews) { EmptyView() }
    }
}

public extension View {
    /// The list owns preview registrations and admitted loads only while it is visible.
    func backupProblemPreviews(_ previews: BackupProblemPreviewModel) -> some View {
        onAppear { previews.open() }
            .onDisappear { previews.close() }
    }
}
