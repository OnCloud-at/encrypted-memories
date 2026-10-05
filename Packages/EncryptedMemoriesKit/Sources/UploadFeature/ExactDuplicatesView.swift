import DesignSystemCore
import PhotosCore
import SwiftUI
import UploadCore

/// The Duplicates route of macOS, iOS, and iPadOS: groups of exact copies, one section per group, like Duplicates in
/// Apple Photos. The shared `ExactDuplicatesModel` owns the groups, the photo to keep, and the merges; this view
/// renders them with a native list and dialogs. The host owns the Merge All toolbar button and sets
/// `confirmsMergeAll`, draws each photo, and opens a photo of a group in its viewer.
public struct ExactDuplicatesView<Cover: View>: View {
    private let model: ExactDuplicatesModel
    @Binding private var confirmsMergeAll: Bool
    private let accent: Color
    private let cornerRadius: CGFloat
    private let onOpen: (PhotoUID, String) -> Void
    private let cover: (PhotoUID) -> Cover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `accent` colors the checkmark and the border of the photo to keep and the progress indicator.
    /// `cornerRadius` is the corner radius of `cover`. `onOpen` receives a photo and the ID of its group.
    public init(
        model: ExactDuplicatesModel, confirmsMergeAll: Binding<Bool>, accent: Color, cornerRadius: CGFloat,
        onOpen: @escaping (PhotoUID, String) -> Void, @ViewBuilder cover: @escaping (PhotoUID) -> Cover
    ) {
        self.model = model
        _confirmsMergeAll = confirmsMergeAll
        self.accent = accent
        self.cornerRadius = cornerRadius
        self.onOpen = onOpen
        self.cover = cover
    }

    public var body: some View {
        content
            // The copies are identical and the duplicates can be restored, so the confirmation is no warning.
            .confirmationDialog(model.mergeAllTitle, isPresented: $confirmsMergeAll, titleVisibility: .visible) {
                Button(model.mergeAllConfirmTitle) {
                    Task { await model.mergeAll() }
                }
                .accessibilityIdentifier("duplicates.mergeAll.dialog")
                Button(L10n.string("action.cancel"), role: .cancel) {}
            } message: {
                Text(model.mergeAllMessage)
            }
            .alert(
                model.notice?.title ?? "",
                isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.dismissNotice() } })
            ) {
                Button(L10n.string("action.ok"), role: .cancel) { model.dismissNotice() }
            } message: {
                Text(model.notice?.message ?? "")
            }
            .task { await model.load() }
            .onDisappear { model.screenDisappeared() }
    }

    /// The waiting and empty states keep a readable width, so a wide Mac window does not stretch their text.
    private static var readableWidth: CGFloat { 600 }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .loading:
            let line = model.loadingLine
            ContentUnavailableView {
                Label(line.title, systemImage: "square.on.square")
            } description: {
                Text(L10n.string("duplicates.loading_message"))
            } actions: {
                progressRow(line, showsTitle: false)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: Self.readableWidth)
            .accessibilityIdentifier("duplicates.loading")
        case .failed(let message):
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.icloud")
            } actions: {
                retryButton
            }
            .frame(maxWidth: Self.readableWidth)
        case .noDuplicates:
            let copy = model.emptyStateCopy
            ContentUnavailableView(copy.title, systemImage: copy.systemImage, description: Text(copy.description))
                .frame(maxWidth: Self.readableWidth)
        case .stillChecking:
            let copy = model.emptyStateCopy
            ContentUnavailableView {
                Label(copy.title, systemImage: copy.systemImage)
            } description: {
                Text(copy.description)
            } actions: {
                if let line = model.checkLine {
                    progressRow(line, showsTitle: false)
                        .frame(maxWidth: 320)
                        .accessibilityIdentifier("duplicates.checkProgress")
                }
            }
            .frame(maxWidth: Self.readableWidth)
        case .groups:
            groupList
        }
    }

    /// The shared progress row. Without its title, the surrounding view shows the title.
    private func progressRow(_ line: ExactDuplicatesModel.ProgressLine, showsTitle: Bool = true) -> some View {
        ActivityProgressRow(
            title: showsTitle ? line.title : nil, detail: line.detail, fraction: line.fraction,
            showsIndeterminateProgress: true
        )
        .tint(accent)
    }

    /// The state of the check and of the ranking above the groups: progress rows while they run, one line after a check
    /// that could not read every photo, and a retry when the check stopped.
    @ViewBuilder private var statusRows: some View {
        if let line = model.checkLine {
            progressRow(line).accessibilityIdentifier("duplicates.checkProgress")
        }
        if let note = model.stillCheckingNote {
            Label(note, systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let line = model.rankingLine {
            progressRow(line).accessibilityIdentifier("duplicates.rankingProgress")
        }
        if let note = model.uncheckedNote {
            Label(note, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("duplicates.unchecked")
        }
        if let note = model.checkFailedNote {
            Label(note, systemImage: "exclamationmark.icloud")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(L10n.string("action.retry")) { Task { await model.load() } }
        }
    }

    @ViewBuilder private var retryButton: some View {
        let retry = Button(L10n.string("action.retry")) { Task { await model.load() } }
        #if os(iOS)
            retry.buttonStyle(.glassProminent)
        #else
            retry
        #endif
    }

    /// The count of the copies with its explanation, and the space that merging all frees.
    @ViewBuilder private var summary: some View {
        if let count = model.copyCountText {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(count)
                        .monospacedDigit()
                        .accessibilityIdentifier("duplicates.copyCount")
                    InfoButton(title: model.infoTitle, message: model.infoMessage)
                        .accessibilityIdentifier("duplicates.info")
                }
                if let freed = model.totalFreedText {
                    Text(freed)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("duplicates.totalFreed")
                }
            }
            .textCase(nil)
        }
    }

    private var groupList: some View {
        let list = List {
            Section {
                statusRows
            } header: {
                summary
            }
            ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                Section {
                    ExactDuplicateMembers(
                        model: model, group: group, groupIndex: index, accent: accent, cornerRadius: cornerRadius,
                        onOpen: onOpen, cover: cover
                    )
                    .accessibilityIdentifier("duplicates.group.\(index)")
                    // Only the groups that the person scrolls to read their facts.
                    .onAppear { model.groupAppeared(group.id) }
                    .animation(factsAnimation, value: group.isRanked)
                    .animation(factsAnimation, value: group.kept)
                } header: {
                    groupHeader(group, index: index)
                } footer: {
                    groupFooter(group, index: index)
                        .animation(factsAnimation, value: group.isRanked)
                }
            }
        }
        #if os(iOS)
            return list.listStyle(.insetGrouped).refreshable { await model.load() }
        #else
            // Apple Photos keeps the groups in a calm column; a wide window adds margins instead of long rows.
            return list.listStyle(.inset)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
        #endif
    }

    /// The facts of a group arrive without a progress row; its badges, its reason, and a moved checkmark fade in.
    /// Without motion, they appear at once.
    private var factsAnimation: Animation? { reduceMotion ? nil : .default }

    /// The capture date of the group and its Merge button, like a group of Duplicates in Apple Photos.
    private func groupHeader(_ group: ExactDuplicatesModel.Group, index: Int) -> some View {
        HStack(alignment: .center) {
            Text(group.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityIdentifier("duplicates.date.\(index)")
            Spacer(minLength: 12)
            Button(L10n.string("duplicates.merge")) {
                Task { await model.merge(groupID: group.id) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(!model.canMerge)
            .accessibilityIdentifier("duplicates.merge.\(index)")
        }
        .textCase(nil)
    }

    /// Why the checked copy stays and what the merge frees, and after a merge why duplicates stayed.
    @ViewBuilder private func groupFooter(_ group: ExactDuplicatesModel.Group, index: Int) -> some View {
        if group.footerText != nil || group.keptReasonMessage != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let footer = group.footerText {
                    Text(footer)
                        .monospacedDigit()
                        .accessibilityIdentifier("duplicates.footer.\(index)")
                }
                if let reason = group.keptReasonMessage {
                    Text(reason)
                        .accessibilityIdentifier("duplicates.keptReason.\(index)")
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// The copies of one group, side by side. A tap or click opens the photo; the context menu keeps it.
private struct ExactDuplicateMembers<Cover: View>: View {
    let model: ExactDuplicatesModel
    let group: ExactDuplicatesModel.Group
    let groupIndex: Int
    let accent: Color
    let cornerRadius: CGFloat
    let onOpen: (PhotoUID, String) -> Void
    let cover: (PhotoUID) -> Cover

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(group.members.enumerated()), id: \.element) { index, uid in
                    let isKept = uid == group.kept
                    let keepTitle = model.keepTitle(for: uid, inGroup: group.id)
                    member(uid, isKept: isKept, keepTitle: keepTitle)
                        .accessibilityLabel(group.accessibilityLabel(of: uid))
                        .accessibilityAddTraits(isKept ? .isSelected : [])
                        .accessibilityAction(named: Text(keepTitle)) { model.keep(uid, inGroup: group.id) }
                        .accessibilityIdentifier("duplicates.member.\(groupIndex).\(index)")
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
    }

    /// A tap or click opens the photo; a long press or a secondary click offers Keep This Copy.
    @ViewBuilder private func member(_ uid: PhotoUID, isKept: Bool, keepTitle: String) -> some View {
        let tile = ExactDuplicateTile(
            group: group, member: uid, accent: accent, cornerRadius: cornerRadius, cover: cover(uid))
        let keep = Button {
            model.keep(uid, inGroup: group.id)
        } label: {
            Label(keepTitle, systemImage: "checkmark.circle")
        }
        .disabled(isKept)
        .accessibilityIdentifier("duplicates.keepMenu")
        #if os(iOS)
            // A context menu inside a List row becomes the menu of the whole row, so a long press on any copy showed
            // the menu of the first one. A menu with a primary action belongs to its own copy.
            Menu {
                keep
            } label: {
                tile
            } primaryAction: {
                onOpen(uid, group.id)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        #else
            Button {
                onOpen(uid, group.id)
            } label: {
                tile
            }
            .buttonStyle(.plain)
            .contextMenu { keep }
        #endif
    }
}

/// One copy: equal to the others, its size at the bottom right and its badges at the bottom left, like Apple Photos.
/// The copy that a merge keeps carries a checkmark and a thin accent border.
private struct ExactDuplicateTile<Cover: View>: View {
    let group: ExactDuplicatesModel.Group
    let member: PhotoUID
    let accent: Color
    let cornerRadius: CGFloat
    let cover: Cover

    /// Apple Photos shows at most two badges on a small thumbnail; the rest is a count.
    private static var visibleBadges: Int { 2 }

    var body: some View {
        let isKept = member == group.kept
        cover
            .overlay(alignment: .bottomLeading) { badges }
            .overlay(alignment: .bottomTrailing) {
                if let size = group.byteSize(of: member) {
                    Text(ExactDuplicatesModel.byteText(size))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .modifier(ThumbnailText())
                }
            }
            .overlay(alignment: .topTrailing) {
                if isKept {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, accent)
                        .shadow(color: .black.opacity(0.3), radius: 1.5)
                        .padding(5)
                }
            }
            .overlay {
                if isKept {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(accent, lineWidth: 2)
                }
            }
    }

    @ViewBuilder private var badges: some View {
        let badges = group.badges(of: member)
        if !badges.isEmpty {
            HStack(spacing: 3) {
                ForEach(badges.prefix(Self.visibleBadges), id: \.self) { badge in
                    Image(systemName: Self.systemImage(of: badge))
                }
                if badges.count > Self.visibleBadges {
                    Text(verbatim: "+\(badges.count - Self.visibleBadges)")
                        .monospacedDigit()
                }
            }
            .font(.caption2.weight(.semibold))
            .modifier(ThumbnailText())
        }
    }

    private static func systemImage(of badge: ExactDuplicateBadge) -> String {
        switch badge {
        case .shared: return "person.2.fill"
        case .album: return "rectangle.stack"
        case .favorite: return "heart.fill"
        case .backedUpHere:
            #if os(macOS)
                return "macbook"
            #else
                return "iphone"
            #endif
        }
    }
}

/// White text on a photo with a subtle shadow, as Apple Photos prints the size on a thumbnail.
private struct ThumbnailText: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
    }
}
