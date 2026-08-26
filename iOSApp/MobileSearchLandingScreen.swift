import DesignSystemCore
import MediaCacheUIKitAdapter
import PhotosCore
import SwiftUI
import TimelineCore
import UIKit

struct MobileSearchLandingScreen: View {
    @Environment(MobileLibraryModel.self) private var libraryModel
    let history: TimelineSearchHistory
    let suggestions: [TimelineSearchSuggestion]
    let recentRepresentatives: [String: PhotoUID]
    let onSelectQuery: (String) -> Void
    let onClearHistory: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !history.queries.isEmpty {
                    recentSection
                }
                suggestionsSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .background(ProtonColor.backgroundNorm)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.string("search.recent"))
                    .font(.title2.bold())
                Spacer()
                Button(L10n.string("search.clear"), action: onClearHistory)
                    .buttonStyle(.bordered)
            }

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(history.queries.prefix(6)), id: \.self) { query in
                        Button {
                            onSelectQuery(query)
                        } label: {
                            MobileSearchCard(
                                title: query,
                                uid: recentRepresentatives[query],
                                thumbnailFeed: libraryModel.thumbnailFeed
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("search.suggestions"))
                .font(.title3.bold())

            if suggestions.isEmpty {
                ContentUnavailableView(
                    L10n.string("search.suggestions_empty"),
                    systemImage: "magnifyingglass",
                    description: Text(L10n.string("search.suggestions_empty_description"))
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
            } else {
                FlowLayout(spacing: 10) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            onSelectQuery(suggestion.query)
                        } label: {
                            Label(suggestion.title, systemImage: "magnifyingglass")
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
            }
        }
    }
}

private struct MobileSearchCard: View {
    let title: String
    let uid: PhotoUID?
    let thumbnailFeed: UIKitThumbnailFeed?
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [ProtonColor.primary.opacity(0.8), Color.indigo.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(width: 150, height: 150)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            Text("“\(title)”")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(12)
        }
        .frame(width: 150, height: 150)
        .clipShape(.rect(cornerRadius: 18))
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
