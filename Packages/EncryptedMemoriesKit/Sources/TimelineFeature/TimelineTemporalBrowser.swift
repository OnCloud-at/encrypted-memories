import AppKit
import DesignSystem
import MediaCache
import PhotosCore
import SwiftUI
import TimelineCore

/// Native macOS presentation for the shared Core year and month projections.
/// The existing Metal grid remains the only All Photos surface.
public struct TimelineTemporalBrowser: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public let projection: TimelineTemporalProjection
    public let thumbnailFeed: ThumbnailFeed
    public let coverImageLoader: TimelineTemporalCoverImageLoader
    public let focusedYear: Int?
    public let onSelectYear: (TimelineTemporalYearGroup) -> Void
    public let onOpenPhotos: (PhotoItem, [PhotoItem]) -> Void

    public init(
        projection: TimelineTemporalProjection,
        thumbnailFeed: ThumbnailFeed,
        coverImageLoader: TimelineTemporalCoverImageLoader,
        focusedYear: Int? = nil,
        onSelectYear: @escaping (TimelineTemporalYearGroup) -> Void,
        onOpenPhotos: @escaping (PhotoItem, [PhotoItem]) -> Void
    ) {
        self.projection = projection
        self.thumbnailFeed = thumbnailFeed
        self.coverImageLoader = coverImageLoader
        self.focusedYear = focusedYear
        self.onSelectYear = onSelectYear
        self.onOpenPhotos = onOpenPhotos
    }

    public var body: some View {
        Group {
            switch projection.status {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.string("library.curation_loading"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(
                    L10n.string("library.view_all_photos"),
                    systemImage: "photo.on.rectangle.angled"
                )
            case .ready:
                switch projection.mode {
                case .years:
                    yearsView
                case .months:
                    monthsView
                case .allPhotos:
                    EmptyView()
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: projection.status)
    }

    private var yearsView: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: TemporalLayout.yearGap),
                    count: 3
                ),
                spacing: TemporalLayout.yearGap
            ) {
                ForEach(projection.yearGroups, id: \.id) { year in
                    Button {
                        onSelectYear(year)
                    } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                if let item = projection.item(for: year.representativeItemUID) {
                                    TemporalCoverTile(
                                        item: item,
                                        feed: thumbnailFeed,
                                        coverImageLoader: coverImageLoader,
                                        title: year.title,
                                        style: .year
                                    )
                                }
                            }
                            .clipped()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(year.title), \(countLabel(year.itemCount))")
                }
            }
            .frame(maxWidth: TemporalLayout.maximumContentWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, TemporalLayout.horizontalPadding)
            .padding(.top, 86)
            .padding(.bottom, 44)
        }
        .defaultScrollAnchor(.bottom)
    }

    private var monthsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 68) {
                ForEach(Array(visibleMonths.enumerated()), id: \.element.id) { index, month in
                    monthSection(month, heroOnTrailingEdge: index.isMultiple(of: 2) == false)
                }
            }
            .padding(.horizontal, TemporalLayout.horizontalPadding)
            .padding(.top, 82)
            .padding(.bottom, 52)
        }
        .defaultScrollAnchor(.bottom)
    }

    private func monthSection(
        _ month: TimelineTemporalMonthGroup,
        heroOnTrailingEdge: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(localizedMonth(month.dateInterval.start))
                    .font(.title.bold())
                if let place = month.placeLabel {
                    Text(place)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let selection = month.editorialSelection {
                monthComposition(
                    selection,
                    in: month,
                    heroOnTrailingEdge: heroOnTrailingEdge
                )
            }
        }
        .frame(maxWidth: TemporalLayout.maximumContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func monthComposition(
        _ selection: TimelineTemporalMonthEditorialSelection,
        in month: TimelineTemporalMonthGroup,
        heroOnTrailingEdge: Bool
    ) -> some View {
        if selection.supportDays.count == 3 {
            GeometryReader { proxy in
                let scale = proxy.size.width / TemporalLayout.maximumContentWidth
                let gap = TemporalLayout.monthGap * scale
                let supportWidth = TemporalLayout.monthSupportWidth * scale
                let heroWidth = proxy.size.width - gap - supportWidth

                HStack(spacing: gap) {
                    if heroOnTrailingEdge {
                        monthSupportColumn(
                            selection.supportDays,
                            month: month,
                            gap: gap,
                            height: proxy.size.height
                        )
                        .frame(width: supportWidth)
                        monthDayButton(selection.heroDay, month: month)
                            .frame(width: heroWidth, height: proxy.size.height)
                    } else {
                        monthDayButton(selection.heroDay, month: month)
                            .frame(width: heroWidth, height: proxy.size.height)
                        monthSupportColumn(
                            selection.supportDays,
                            month: month,
                            gap: gap,
                            height: proxy.size.height
                        )
                        .frame(width: supportWidth)
                    }
                }
            }
            .aspectRatio(TemporalLayout.monthCompositionAspectRatio, contentMode: .fit)
        } else {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: TemporalLayout.monthGap),
                    count: max(1, selection.supportDays.count + 1)
                ),
                spacing: TemporalLayout.monthGap
            ) {
                boundedMonthDayButton(selection.heroDay, month: month)
                ForEach(selection.supportDays, id: \.id) { day in
                    boundedMonthDayButton(day, month: month)
                }
            }
        }
    }

    private func monthSupportColumn(
        _ days: [TimelineTemporalDayGroup],
        month: TimelineTemporalMonthGroup,
        gap: CGFloat,
        height: CGFloat
    ) -> some View {
        let cardHeight = (height - (2 * gap)) / 3
        return VStack(spacing: gap) {
            ForEach(days, id: \.id) { day in
                monthDayButton(day, month: month)
                    .frame(height: cardHeight)
            }
        }
        .frame(height: height)
    }

    private func monthDayButton(
        _ day: TimelineTemporalDayGroup,
        month: TimelineTemporalMonthGroup
    ) -> some View {
        Button {
            open(day, in: month)
        } label: {
            if let item = projection.item(for: day.representativeItemUID) {
                TemporalCoverTile(
                    item: item,
                    feed: thumbnailFeed,
                    coverImageLoader: coverImageLoader,
                    title: dayNumber(day.dateInterval.start),
                    style: .day
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(localizedDay(day.dateInterval.start)), \(countLabel(day.itemCount))")
    }

    private func boundedMonthDayButton(
        _ day: TimelineTemporalDayGroup,
        month: TimelineTemporalMonthGroup
    ) -> some View {
        Color.clear
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                monthDayButton(day, month: month)
            }
            .clipped()
    }

    private var visibleMonths: [TimelineTemporalMonthGroup] {
        guard let focusedYear else { return projection.monthGroups }
        let calendar = Calendar.current
        return projection.monthGroups.filter {
            calendar.component(.year, from: $0.dateInterval.start) == focusedYear
        }
    }

    private func open(_ day: TimelineTemporalDayGroup, in month: TimelineTemporalMonthGroup) {
        let items = month.itemUIDs.compactMap { projection.item(for: $0) }
        guard let item = projection.item(for: day.representativeItemUID) else { return }
        onOpenPhotos(item, items)
    }

    private func localizedMonth(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }

    private func localizedDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    private func dayNumber(_ date: Date) -> String {
        date.formatted(.dateTime.day())
    }

    private func countLabel(_ count: Int) -> String {
        count == 1
            ? L10n.string("library.photo_singular")
            : "\(count) \(L10n.string("library.photos_plural"))"
    }
}

private enum TemporalLayout {
    static let maximumContentWidth: CGFloat = 1_380
    static let horizontalPadding: CGFloat = 28
    static let yearGap: CGFloat = 40
    static let monthGap: CGFloat = 24
    static let monthSupportWidth: CGFloat = 398
    static let monthCompositionAspectRatio: CGFloat = 1_380 / 719
}

private enum TemporalCoverStyle {
    case year
    case day

    var font: Font {
        switch self {
        case .year:
            return .largeTitle.bold()
        case .day:
            return .title2.bold()
        }
    }

    var padding: CGFloat {
        switch self {
        case .year:
            return 24
        case .day:
            return 16
        }
    }
}

private struct TemporalCoverTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    let item: PhotoItem
    let feed: ThumbnailFeed
    let coverImageLoader: TimelineTemporalCoverImageLoader
    let title: String
    let style: TemporalCoverStyle

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [Color.indigo.opacity(0.72), Color.purple.opacity(0.32)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        ProgressView()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()

                LinearGradient(
                    colors: [.black.opacity(0.58), .black.opacity(0.16), .clear],
                    startPoint: .top,
                    endPoint: .center
                )

                Text(title)
                    .font(style.font)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(style.padding)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: taskID(for: proxy.size)) {
                await load(targetPixelSize: targetPixelSize(for: proxy.size))
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .contentShape(.rect)
    }

    @MainActor
    private func load(targetPixelSize: TimelineTemporalPixelSize) async {
        image = memoryImage()
        if image == nil {
            image = await feed.image(for: item.uid)
        }
        guard !Task.isCancelled else { return }

        // Proton grid thumbnails are compact derivatives. Decoding beyond the
        // measured source dimensions cannot add detail, so cap this first stage.
        _ = await feed.warmVisibleDecoded(
            [ThumbnailRequest(uid: item.uid, pixelSize: min(512, targetPixelSize.longestEdge))],
            limit: 1
        )
        guard !Task.isCancelled else { return }

        if let thumbnail = feed.memoryCGImage(for: item.uid) {
            present(thumbnail)
            let thumbnailSize = TimelineTemporalPixelSize(
                width: thumbnail.width,
                height: thumbnail.height
            )
            if TimelineTemporalCoverResolutionPolicy.sourceFillsTargetWithoutUpscaling(
                source: thumbnailSize,
                target: targetPixelSize
            ) {
                return
            }
        }

        // Window resizing can replace the target several times. Debounce the
        // network-backed quality stages while keeping the thumbnail immediate.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }

        if let preview = await coverImageLoader.previewCandidate(
            for: item,
            targetPixelSize: targetPixelSize
        ), !Task.isCancelled {
            present(preview.decoded.image)
            if preview.fillsTargetWithoutUpscaling { return }
        }

        guard
            let original = await coverImageLoader.originalCandidate(
                for: item,
                targetPixelSize: targetPixelSize
            ), !Task.isCancelled
        else { return }
        present(original.decoded.image)
    }

    private func targetPixelSize(for size: CGSize) -> TimelineTemporalPixelSize {
        TimelineTemporalPixelSize(
            width: Int(ceil(size.width * displayScale)),
            height: Int(ceil(size.height * displayScale))
        )
    }

    private func taskID(for size: CGSize) -> TemporalCoverTaskID {
        TemporalCoverTaskID(uid: item.uid, targetPixelSize: targetPixelSize(for: size))
    }

    @MainActor
    private func present(_ cgImage: CGImage) {
        let upgraded = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        if image == nil || reduceMotion {
            image = upgraded
        } else {
            withAnimation(.easeInOut(duration: 0.16)) {
                image = upgraded
            }
        }
    }

    private func memoryImage() -> NSImage? {
        guard let cgImage = feed.memoryCGImage(for: item.uid) else {
            return feed.memoryImage(for: item.uid)
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

private struct TemporalCoverTaskID: Hashable {
    let uid: PhotoUID
    let targetPixelSize: TimelineTemporalPixelSize
}
