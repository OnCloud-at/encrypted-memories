import DesignSystemCore
import MediaCacheUIKitAdapter
import PhotosCore
import SwiftUI
import TimelineCore
import UIKit

/// One entry of the in-memory search history with the preview shown next to it.
struct MobileSearchRecentEntry: Identifiable, Equatable {
    let query: String
    let representativeUID: PhotoUID?
    /// Set when the entry came from a structured suggestion, so selecting it again restores the same result.
    let suggestion: TimelineSearchSuggestion?

    var id: String { query }
}

/// Everything the search landing shows while the search field is empty. The native search field itself stays
/// owned by the Search tab; the landing only scrolls above it.
struct MobileSearchLandingContent {
    var recents: [MobileSearchRecentEntry] = []
    var discovery: MobileSearchDiscoveryModel?
    var onSelectRecent: (MobileSearchRecentEntry) -> Void = { _ in }
    var onSelectSuggestion: (TimelineSearchSuggestion) -> Void = { _ in }
    var onClearHistory: () -> Void = {}
}

struct MobileSearchLandingScreen: View {
    @Environment(MobileLibraryModel.self) private var libraryModel
    let content: MobileSearchLandingContent

    private var discovery: MobileSearchDiscoveryModel? { content.discovery }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !content.recents.isEmpty {
                    recentSection
                }
                forYouSection
                if let chips = discovery?.chips, !chips.isEmpty {
                    chipSection(chips)
                }
                notes
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ProtonColor.backgroundNorm)
    }

    // MARK: Sections

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(L10n.string("search.recent_searches"))
                Spacer()
                Button(L10n.string("search.clear"), action: content.onClearHistory)
                    .font(.subheadline)
            }
            VStack(spacing: 0) {
                ForEach(Array(content.recents.prefix(5).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider().padding(.leading, 60)
                    }
                    Button {
                        content.onSelectRecent(entry)
                    } label: {
                        HStack(spacing: 12) {
                            MobileSearchThumbnail(
                                uid: entry.representativeUID,
                                size: 44,
                                cornerRadius: 10,
                                placeholderSymbol: "clock.arrow.circlepath",
                                thumbnailFeed: libraryModel.thumbnailFeed
                            )
                            Text(entry.query)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.left")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var forYouSection: some View {
        let suggestions = discovery?.forYou ?? []
        let isLoading = discovery?.hasComputed != true
        if isLoading || !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle(L10n.string("search.for_you"))
                VStack(spacing: 0) {
                    if isLoading {
                        ForEach(0..<3, id: \.self) { index in
                            if index > 0 { Divider().padding(.leading, 132) }
                            MobileSearchSuggestionRow(
                                suggestion: nil,
                                thumbnailFeed: libraryModel.thumbnailFeed
                            )
                        }
                        .redacted(reason: .placeholder)
                        .accessibilityHidden(true)
                    } else {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            if index > 0 { Divider().padding(.leading, 132) }
                            Button {
                                content.onSelectSuggestion(suggestion)
                            } label: {
                                MobileSearchSuggestionRow(
                                    suggestion: suggestion,
                                    thumbnailFeed: libraryModel.thumbnailFeed
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } else if content.recents.isEmpty {
            ContentUnavailableView(
                L10n.string("search.suggestions_empty"),
                systemImage: "magnifyingglass",
                description: Text(L10n.string("search.suggestions_empty_description"))
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
        }
    }

    private func chipSection(_ chips: [TimelineSearchSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(L10n.string("search.discover"))
            FlowLayout(spacing: 10) {
                ForEach(chips) { chip in
                    Button {
                        content.onSelectSuggestion(chip)
                    } label: {
                        Label(chip.title, systemImage: chip.systemImage)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
        }
    }

    @ViewBuilder private var notes: some View {
        if discovery?.showsIndexingNote == true {
            Label(L10n.string("search.suggestions_indexing"), systemImage: "sparkles")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if discovery?.showsSmartSearchHint == true, discovery?.hasComputed == true {
            Label(L10n.string("search.suggestions_ml_hint"), systemImage: "sparkle.magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
    }
}

/// A "For You" row: two previews from the matching photos, the title and the match count.
private struct MobileSearchSuggestionRow: View {
    let suggestion: TimelineSearchSuggestion?
    let thumbnailFeed: UIKitThumbnailFeed?

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { index in
                    MobileSearchThumbnail(
                        uid: suggestion.flatMap {
                            index < $0.representativeUIDs.count ? $0.representativeUIDs[index] : nil
                        },
                        size: 56,
                        cornerRadius: 12,
                        placeholderSymbol: suggestion?.systemImage ?? "photo",
                        thumbnailFeed: thumbnailFeed
                    )
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion?.title ?? "Placeholder suggestion")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle = suggestion?.subtitle ?? (suggestion == nil ? "000 photos" : nil) {
                    Label(subtitle, systemImage: suggestion?.systemImage ?? "photo")
                        .labelStyle(MobileSearchSubtitleLabelStyle())
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct MobileSearchSubtitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .imageScale(.small)
            configuration.title
                .lineLimit(1)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// A square preview from the authenticated thumbnail cache, with a symbol while it loads or when no item exists.
private struct MobileSearchThumbnail: View {
    let uid: PhotoUID?
    let size: CGFloat
    let cornerRadius: CGFloat
    let placeholderSymbol: String
    let thumbnailFeed: UIKitThumbnailFeed?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProtonColor.primary.opacity(0.18)
                Image(systemName: placeholderSymbol)
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(ProtonColor.primary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task(id: uid) {
            guard let uid, let thumbnailFeed else {
                image = nil
                return
            }
            image = thumbnailFeed.memoryImage(for: uid)
            if image == nil {
                image = await thumbnailFeed.image(for: uid)
            }
        }
    }
}

/// A compact wrapping layout keeps localized suggestions readable on every iPhone width.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? 320
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}
