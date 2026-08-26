import AppKit
import DesignSystem
import GridCore
import PhotosCore
import SwiftUI
import TimelineCore

public struct TimelineView: View {
    @State private var model: TimelineViewModel
    @Binding private var level: Int
    /// Leading overlap of the floating sidebar (0 when collapsed). The grid lays its tiles out past this inset
    /// itself, but the SwiftUI placeholder/empty/error states are plain centered views - without this they'd
    /// center over the full detail width (which runs under the sidebar) and read as shifted too far left.
    @Environment(\.gridLeadingEventInset) private var leadingInset: CGFloat
    private let onOpen: (PhotoItem, [PhotoItem]) -> Void
    private let proxy: GridProxy<PhotoUID>?
    private let routeScrollGeneration: Int
    private let routeInitialScrollAnchor: GridScrollAnchor<PhotoUID>?
    private let searchText: String
    /// True while the semantic engine is resolving the current non-empty query. During this
    /// phase the timeline must not expose lexical fallback content or a premature empty state.
    private let isSearchPending: Bool
    /// UIDs the on-device Smart Search ranked for `searchText` (nil = semantic search inactive).
    private let semanticMatches: Set<PhotoUID>?
    private let selectionMode: Bool
    private let onSelectionChange: (Set<PhotoUID>) -> Void
    private let media: FullMediaProvider?
    private let metadataProvider: PhotoMetadataProvider?
    private let favoriteUIDs: Set<PhotoUID>
    private let isOffline: Bool
    private let gridProfile: GridLevelProfile
    private let gridProfileResolver: TimelineGridProfileResolver?
    private let gridFillOrder: GridFillOrder
    private let initialViewportPlacement: TimelineInitialViewportPlacement
    @State private var searchProjection: TimelineSearchProjection?
    @State private var searchCoordinator: TimelineSearchProjectionCoordinator
    @State private var monthMarkers: [TimelineDateMarker] = []
    @State private var monthMarkerRevision: Int?

    public init(
        model: TimelineViewModel,
        level: Binding<Int>? = nil,
        gridProfile: GridLevelProfile = TimelineGridProfiles.productionDefaultProfile,
        gridFillOrder: GridFillOrder = .newestBottomTrailing,
        initialViewportPlacement: TimelineInitialViewportPlacement = .automatic,
        proxy: GridProxy<PhotoUID>? = nil,
        routeScrollGeneration: Int = 0,
        routeInitialScrollAnchor: GridScrollAnchor<PhotoUID>? = nil,
        searchText: String = "",
        isSearchPending: Bool = false,
        semanticMatches: Set<PhotoUID>? = nil,
        selectionMode: Bool = false,
        media: FullMediaProvider? = nil,
        metadataProvider: PhotoMetadataProvider? = nil,
        favoriteUIDs: Set<PhotoUID> = [],
        isOffline: Bool = false,
        onSelectionChange: @escaping (Set<PhotoUID>) -> Void = { _ in },
        onOpen: @escaping (PhotoItem, [PhotoItem]) -> Void = { _, _ in }
    ) {
        _model = State(initialValue: model)
        _level = level ?? .constant(gridProfile.defaultLevel)
        self.gridProfile = gridProfile
        self.gridFillOrder = gridFillOrder
        self.initialViewportPlacement = initialViewportPlacement
        let productionConfig = TimelineGridProfileConfiguration.production
        self.gridProfileResolver = gridProfile == productionConfig.defaultProfile ? productionConfig.resolver : nil
        self.proxy = proxy
        self.routeScrollGeneration = routeScrollGeneration
        self.routeInitialScrollAnchor = routeInitialScrollAnchor
        self.searchText = searchText
        self.isSearchPending = isSearchPending
        self.semanticMatches = semanticMatches
        self.selectionMode = selectionMode
        self.media = media
        self.metadataProvider = metadataProvider
        self.favoriteUIDs = favoriteUIDs
        self.isOffline = isOffline
        self.onSelectionChange = onSelectionChange
        self.onOpen = onOpen
        _searchProjection = State(initialValue: nil)
        _searchCoordinator = State(initialValue: TimelineSearchProjectionCoordinator())
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                // Route switches (RAW / album / trash …) show the same animated Proton mark as the app's launch
                // veil - never a black surface, never a stale grid. The leading inset keeps the 64pt mark
                // centered in the visible area when the floating sidebar is open.
                if isOffline {
                    OfflineContentUnavailableView()
                        .padding(.leading, leadingInset)
                } else {
                    LoadingMark()
                        .frame(width: 64, height: 64)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, leadingInset)
                }
            case .empty:
                emptyState
                    .padding(.leading, leadingInset)
            case .failed(let message):
                if isOffline {
                    OfflineContentUnavailableView()
                        .padding(.leading, leadingInset)
                } else {
                    errorState(message)
                        .padding(.leading, leadingInset)
                }
            case .loaded:
                let showsMonthLabels = gridProfile.showsMonthLabels(level: level)
                ZStack(alignment: .trailing) {
                    if isEmptySearchResult {
                        searchEmptyState
                            .padding(.leading, leadingInset)
                    } else if !displayedItems.isEmpty {
                        MetalProductionGridView(
                            sections: displayedSections,
                            allItems: displayedItems,
                            dataRevision: gridDataRevision,
                            sourceRevision: model.gridSourceRevision,
                            feed: model.feed,
                            level: $level,
                            routeScrollGeneration: routeScrollGeneration,
                            routeInitialScrollAnchor: routeInitialScrollAnchor,
                            gridProfile: gridProfile,
                            gridProfileResolver: gridProfileResolver,
                            gridFillOrder: gridFillOrder,
                            initialViewportPlacement: initialViewportPlacement,
                            onOpen: onOpen,
                            proxy: proxy,
                            selectionMode: selectionMode,
                            onSelectionChange: onSelectionChange,
                            favoriteUIDs: favoriteUIDs,
                            media: media,
                            metadataProvider: metadataProvider
                        )
                        .ignoresSafeArea(edges: .bottom)

                        if showsMonthLabels,
                            monthMarkerRevision == gridDataRevision,
                            monthMarkers.count > 1
                        {
                            TimelineDateScrubber(markers: monthMarkers) { marker in
                                proxy?.scrollToFlatIndex?(marker.index)
                            }
                        }
                    }

                    if isSearchResultPending {
                        LoadingMark()
                            .frame(width: 64, height: 64)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.leading, leadingInset)
                            .background(timelineSurfaceBackground)
                            .transition(.opacity)
                    }
                }
            }
        }
        .background(timelineSurfaceBackground)
        .task { await model.load() }
        .task(id: searchProjectionRequest) { await resolveSearchProjection() }
        .task(id: markerRequest) { await resolveMonthMarkers(for: markerRequest) }
        .onChange(of: hasSearchQuery) { _, hasQuery in
            guard !hasQuery else { return }
            searchProjection = nil
            Task { await searchCoordinator.cancel() }
        }
        .onAppear { MetalGridRuntime.logResolutionOnce() }
    }

    private var timelineSurfaceBackground: Color {
        Color(nsColor: MetalGridPalette.background)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyStateCopy.title, systemImage: emptyStateCopy.systemImage)
        } description: {
            Text(emptyStateCopy.description)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(timelineSurfaceBackground)
    }

    private var emptyStateCopy: (title: String, description: String, systemImage: String) {
        let copy = model.filter.emptyStateCopy
        return (copy.title, copy.description, copy.systemImage)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label(L10n.string("error.load_library_title"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            Button(L10n.string("action.retry")) { Task { await model.retry() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(timelineSurfaceBackground)
    }

    private var searchEmptyState: some View {
        ContentUnavailableView.search(text: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(timelineSurfaceBackground)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSearchQuery: Bool {
        !TimelineSearchQuery(normalizedSearchText).isEmpty
    }

    private var searchKey: TimelineSearchProjectionKey {
        TimelineSearchProjectionKey(
            sourceRevision: model.contentRevision,
            query: normalizedSearchText,
            context: TimelineSearchContext(activeFilter: model.filter, favoriteUIDs: favoriteUIDs),
            semanticMatches: semanticMatches
        )
    }

    private var searchProjectionRequest: TimelineSearchProjectionKey? {
        guard hasSearchQuery, !isSearchPending else { return nil }
        return searchKey
    }

    private var resolvedSearchProjection: TimelineSearchProjection? {
        guard hasSearchQuery, searchProjection?.key == searchKey else { return nil }
        return searchProjection
    }

    private var displayedSections: [TimelineSection] {
        guard hasSearchQuery else { return model.currentSections }
        return (resolvedSearchProjection ?? searchProjection)?.sections ?? model.currentSections
    }

    private var displayedItems: [PhotoItem] {
        guard hasSearchQuery else { return model.allItems }
        return (resolvedSearchProjection ?? searchProjection)?.snapshot.items ?? model.allItems
    }

    private var isSearchResultPending: Bool {
        hasSearchQuery && (isSearchPending || resolvedSearchProjection == nil)
    }

    private var isEmptySearchResult: Bool {
        hasSearchQuery && !isSearchResultPending && resolvedSearchProjection?.snapshot.isEmpty == true
    }

    private var gridDataRevision: Int {
        if hasSearchQuery, let projection = resolvedSearchProjection ?? searchProjection {
            return Int(truncatingIfNeeded: projection.revision &* 2 &+ 1)
        }
        return Int(truncatingIfNeeded: model.gridSourceRevision &* 2)
    }

    private var markerRequest: TimelineMarkerRequest {
        TimelineMarkerRequest(
            dataRevision: gridDataRevision,
            showsMonthLabels: gridProfile.showsMonthLabels(level: level)
        )
    }

    private func resolveSearchProjection() async {
        guard let key = searchProjectionRequest else { return }
        let sections = model.currentSections
        guard let projection = await searchCoordinator.resolve(sections: sections, key: key),
            !Task.isCancelled,
            searchProjectionRequest == key
        else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            searchProjection = projection
        }
    }

    private func resolveMonthMarkers(for request: TimelineMarkerRequest) async {
        guard request.showsMonthLabels else {
            monthMarkers = []
            monthMarkerRevision = request.dataRevision
            return
        }
        monthMarkerRevision = nil
        let items = displayedItems
        let task = Task.detached(priority: .userInitiated) {
            MetalGridProductionAdapter.dateMarkers(items: items, granularity: .month)
        }
        let markers = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, markerRequest == request else { return }
        monthMarkers = markers
        monthMarkerRevision = request.dataRevision
    }
}

private struct TimelineMarkerRequest: Hashable {
    let dataRevision: Int
    let showsMonthLabels: Bool
}

private struct TimelineDateScrubber: View {
    let markers: [TimelineDateMarker]
    let onJump: (TimelineDateMarker) -> Void

    @State private var activeIndex: Int?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let active = activeIndex.flatMap { markers[safe: $0] }
            ZStack(alignment: .trailing) {
                Color.clear
                    .frame(width: hovering || active != nil ? 7 : 4)
                    .protonGlass(in: Capsule(style: .continuous))
                    .opacity(hovering || active != nil ? 0.72 : 0.22)
                    .padding(.trailing, 10)

                if let active, let index = activeIndex {
                    Text(active.text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .protonGlass(in: Capsule(style: .continuous))
                        .position(
                            x: geometry.size.width - 66,
                            y: markerY(index: index, height: geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = markerIndex(at: value.location.y, height: geometry.size.height)
                        guard activeIndex != index, let marker = markers[safe: index] else { return }
                        activeIndex = index
                        onJump(marker)
                    }
                    .onEnded { _ in activeIndex = nil }
            )
            .onHover { hovering = $0 }
        }
        .frame(width: hovering || activeIndex != nil ? 112 : 32)
        .padding(.trailing, 8)
        .padding(.vertical, 96)
        .allowsHitTesting(markers.count > 1)
    }

    private func markerIndex(at y: CGFloat, height: CGFloat) -> Int {
        guard markers.count > 1 else { return 0 }
        let normalized = min(max(y / max(height, 1), 0), 1)
        return min(markers.count - 1, max(0, Int((normalized * CGFloat(markers.count)).rounded(.down))))
    }

    private func markerY(index: Int, height: CGFloat) -> CGFloat {
        guard markers.count > 1 else { return height / 2 }
        let q = CGFloat(index) / CGFloat(markers.count - 1)
        return min(max(12, q * height), max(12, height - 12))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
