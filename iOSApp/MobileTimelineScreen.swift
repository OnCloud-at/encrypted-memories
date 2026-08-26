import AlbumCore
import AlbumsFeature
import DesignSystemCore
import Foundation
import GridCore
import MLSearchCore
import PhotoViewerCore
import PhotosCore
import SwiftUI
import TimelineCore
import TimelineUIKitFeature
import UIKit

enum MobileTimelineSurface: Equatable {
    case library
    case search

    var title: String {
        switch self {
        case .library: L10n.string("library.title")
        case .search: String(localized: "tab.search")
        }
    }
}

/// The shared library and search timeline. Each native tab owns only its presentation state; both surfaces
/// use the same Metal grid, projection pipeline, selection contract and viewer router.
struct MobileTimelineScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(MobileLibraryModel.self) private var model
    let surface: MobileTimelineSurface
    /// Whether the Photos tab is the active surface. Threaded into the grid so a hidden grid stops its
    /// render loop; defaults to true so previews/other embeds keep the grid live.
    var isActive: Bool = true
    /// Bumped when the active library tab is retapped. The grid observes it and performs the scroll.
    var scrollToLatestSignal: Int = 0
    @Binding private var searchText: String
    @Binding private var searchScope: MLSearchScope
    private let searchHistory: TimelineSearchHistory
    private let searchSuggestions: [TimelineSearchSuggestion]
    private let searchRecentRepresentatives: [String: PhotoUID]
    private let onSelectSearchQuery: (String) -> Void
    private let onClearSearchHistory: () -> Void
    @Environment(MobileViewerRouter.self) private var viewerRouter
    @State private var selection = MobileGridSelectionController()
    @State private var networkMonitor = NetworkMonitor.shared
    /// Frosted-bar height, read once from the key window and cached. Reading it during `body` would cycle
    /// layout under the safe-area-ignoring overlay.
    @State private var topFrostHeight: CGFloat = mobileTopBarFrostHeightDefault
    // Search uses the same shared coordinator as macOS. Core owns semantic/native execution and
    // rank fusion; this view only commits the resulting UID order to the grid.
    @State private var committedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var semanticQuery: MLSmartSearchQueryCoordinator?
    /// Identity of the lifecycle the coordinator is bound to - a new session rebinds it.
    @State private var semanticQueryLifecycle: ObjectIdentifier?
    @State private var searchProjection: TimelineSearchProjection?
    @State private var searchCoordinator = TimelineSearchProjectionCoordinator()
    /// Apple-style stacked library refinements. Core evaluates these off-main with AND semantics across
    /// independent groups and OR semantics within the media-kind group.
    @State private var refinement: TimelineRefinement = .all
    @State private var displayMode: TileContentDisplayMode = .squareFillCrop
    @State private var gridProxy = GridProxy<PhotoUID>()
    @State private var searchReturnAnchor: GridScrollAnchor<PhotoUID>?
    @State private var projectionRestoreAnchor: GridScrollAnchor<PhotoUID>?
    @State private var projectionRestoreSignal = 0
    @State private var contentTransitionSignal = 0
    @State private var refinementTopPlacementSignal = 0
    @State private var refinementTopPlacementPending = false
    @State private var searchSessionActive = false
    @State private var showAlbumPicker = false
    @State private var showSettings = false
    /// The native toolbar keeps its slots mounted from frame one, but its content appears only after the
    /// launch cover has finished dissolving. This prevents both chrome-over-cover and title relocation.
    @State private var launchChromeVisible = false

    init(
        surface: MobileTimelineSurface = .library,
        isActive: Bool = true,
        scrollToLatestSignal: Int = 0,
        searchText: Binding<String> = .constant(""),
        searchScope: Binding<MLSearchScope> = .constant(.all),
        searchHistory: TimelineSearchHistory = TimelineSearchHistory(),
        searchSuggestions: [TimelineSearchSuggestion] = [],
        searchRecentRepresentatives: [String: PhotoUID] = [:],
        onSelectSearchQuery: @escaping (String) -> Void = { _ in },
        onClearSearchHistory: @escaping () -> Void = {}
    ) {
        self.surface = surface
        self.isActive = isActive
        self.scrollToLatestSignal = scrollToLatestSignal
        _searchText = searchText
        _searchScope = searchScope
        self.searchHistory = searchHistory
        self.searchSuggestions = searchSuggestions
        self.searchRecentRepresentatives = searchRecentRepresentatives
        self.onSelectSearchQuery = onSelectSearchQuery
        self.onClearSearchHistory = onClearSearchHistory
    }

    /// Indicates that a selection action is running, so the other toolbar buttons disable together.
    private var selectionBusy: Bool { selection.isBusy }

    private var canSelect: Bool { model.loadState.isContentReady && !model.items.isEmpty }
    private var backgroundLibraryActivityActive: Bool {
        return model.isBackgroundLoading
    }
    private var connectivityBannerState: LibraryConnectivityBannerState {
        .resolve(
            isOnline: networkMonitor.isOnline,
            didRecentlyRestoreConnection: networkMonitor.didRecentlyRestoreConnection
        )
    }
    private var libraryBannerIsPresented: Bool {
        connectivityBannerState != .hidden || backgroundLibraryActivityActive
    }
    private var libraryBannerMessage: String {
        switch connectivityBannerState {
        case .offline:
            L10n.string("library.title_offline")
        case .connectionRestored:
            L10n.string("library.title_online_restored")
        case .hidden:
            "\(L10n.string("library.title_activity")) …"
        }
    }
    private var libraryBannerVisualState: LibraryActivityBannerState {
        switch connectivityBannerState {
        case .offline:
            .offline
        case .connectionRestored:
            .success
        case .hidden:
            .working
        }
    }

    var body: some View {
        NavigationStack {
            content
                .mobileNavigationTitle(
                    surface.title,
                    isVisible: launchChromeVisible
                )
                .toolbar { toolbarContent }
                .toolbar(selection.isSelecting ? .hidden : .automatic, for: .tabBar)
                .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: selection.isSelecting)
                .onChange(of: searchScope) { _, scope in semanticQuery?.setScope(scope) }
                .onChange(of: searchText) { _, value in scheduleSearchCommit(value) }
                .onDisappear {
                    searchDebounceTask?.cancel()
                    searchDebounceTask = nil
                }
                .task(id: searchProjectionRequest) { await resolveSearchProjection() }
                .onChange(of: hasProjectionCriteria) { _, hasCriteria in
                    guard !hasCriteria else { return }
                    refinementTopPlacementPending = false
                    searchProjection = nil
                    Task { await searchCoordinator.cancel() }
                }
                .task(id: showsLibraryLoadingCover) {
                    if showsLibraryLoadingCover {
                        launchChromeVisible = false
                        return
                    }
                    if reduceMotion {
                        launchChromeVisible = true
                    } else {
                        withAnimation(.easeInOut(duration: LibraryLoadingCoverMetrics.fadeDuration)) {
                            launchChromeVisible = true
                        }
                    }
                }
        }
        .overlay {
            LibraryActivityBannerOverlay(
                isPresented: libraryBannerIsPresented,
                message: libraryBannerMessage,
                state: libraryBannerVisualState,
                bottomPadding: selection.isSelecting ? 84 : 20
            )
        }
        .mobileSharePresentation(selection: selection)
        .sheet(isPresented: $showSettings) {
            MobileSettingsScreen(showsDismissButton: true)
        }
        .mobileSelectionAlerts(selection: selection) { performTrash() }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if surface == .library {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .disabled(selection.isSelecting)
                .opacity(launchChromeVisible && !selection.isSelecting ? 1 : 0)
                .allowsHitTesting(launchChromeVisible && !selection.isSelecting)
                .accessibilityLabel(String(localized: "library.account_settings"))
                .accessibilityHidden(!launchChromeVisible || selection.isSelecting)
            }
            .sharedBackgroundVisibility(launchChromeVisible && !selection.isSelecting ? .automatic : .hidden)
        }
        // Keep every trailing slot present from the first rendered frame. Adding either control after the
        // library becomes ready makes SwiftUI recompute the semantic `.title` placement and visibly jump it.
        if surface == .library {
            ToolbarItem(placement: .topBarTrailing) {
                ZStack {
                    libraryOptionsMenu
                        .opacity(selection.isSelecting ? 0 : 1)
                        .allowsHitTesting(!selection.isSelecting)
                        .accessibilityHidden(selection.isSelecting)

                    selectionOptionsMenu
                        .opacity(selection.isSelecting ? 1 : 0)
                        .allowsHitTesting(selection.isSelecting)
                        .accessibilityHidden(!selection.isSelecting)
                }
                .disabled(!canSelect)
                .opacity(launchChromeVisible ? 1 : 0)
                .allowsHitTesting(launchChromeVisible)
                .accessibilityHidden(!launchChromeVisible)
            }
            .sharedBackgroundVisibility(launchChromeVisible ? .automatic : .hidden)
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(selection.isSelecting ? L10n.string("action.done") : L10n.string("action.select")) {
                selection.toggleMode(reduceMotion: reduceMotion)
            }
            .disabled(!canSelect)
            .opacity(launchChromeVisible ? 1 : 0)
            .allowsHitTesting(launchChromeVisible)
            .accessibilityHidden(!launchChromeVisible)
        }
        .sharedBackgroundVisibility(launchChromeVisible ? .automatic : .hidden)
        // Keep all item identities mounted. The system can then morph the bar as one native transition.
        ToolbarItem(placement: .bottomBar) {
            HStack {
                Button {
                    startShare()
                } label: {
                    if selection.isExporting {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(selection.selected.isEmpty || selectionBusy)
                .accessibilityLabel(String(localized: "selection.share_a11y"))

                Spacer(minLength: 28)

                Button {
                    showAlbumPicker = true
                } label: {
                    Text(selectionCenterText ?? "")
                        .font(.body)
                        .monospacedDigit()
                        .fixedSize()
                }
                .disabled(selection.selected.isEmpty || selectionBusy || model.albumActions?.canAddPhotos != true)
                .accessibilityLabel(L10n.string("albums.add_selection_title"))
                .popover(isPresented: $showAlbumPicker, arrowEdge: .bottom) {
                    if let coordinator = model.albumActions {
                        AlbumDestinationPicker(
                            coordinator: coordinator,
                            photoUIDs: model.selectedUIDs(selection.selected),
                            onAlbumsChanged: { model.noteAlbumsChanged() },
                            onCompleted: { _ in
                                showAlbumPicker = false
                                selection.finish(reduceMotion: reduceMotion)
                            }
                        )
                    }
                }

                Spacer(minLength: 28)

                Button(role: .destructive) {
                    selection.showTrashConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selection.selected.isEmpty || selectionBusy)
                .accessibilityLabel(String(localized: "selection.trash_a11y"))
            }
            .frame(minWidth: 300)
            .opacity(selection.isSelecting ? 1 : 0)
            .allowsHitTesting(selection.isSelecting)
            .accessibilityHidden(!selection.isSelecting)
        }
        .sharedBackgroundVisibility(selection.isSelecting ? .automatic : .hidden)
    }

    private var libraryOptionsMenu: some View {
        Menu {
            Menu {
                Section {
                    Button {
                        resetRefinement()
                    } label: {
                        Label(
                            String(localized: "library.filter_all"),
                            systemImage: refinement.isActive ? "square.grid.3x3" : "checkmark"
                        )
                    }
                }

                Section {
                    Toggle(isOn: favoritesFilterBinding) {
                        Label(PhotoTag.favorites.title, systemImage: "heart")
                    }
                    .disabled(model.favoriteFilterAvailability != .available)
                    Toggle(isOn: mediaKindBinding(.photo)) {
                        Label(String(localized: "library.filter_photos"), systemImage: "photo")
                    }
                    Toggle(isOn: mediaKindBinding(.video)) {
                        Label(PhotoTag.videos.title, systemImage: "video")
                    }
                }

                if refinement.isActive {
                    Section {
                        Button {
                            resetRefinement()
                        } label: {
                            Label(String(localized: "library.filter_remove"), systemImage: "minus.circle")
                        }
                    }
                }
            } label: {
                Label(
                    refinement.isActive ? refinementSummary : String(localized: "library.filter"),
                    systemImage: "line.3.horizontal.decrease"
                )
            }

            Menu {
                let availability =
                    gridProxy.zoomAvailability?()
                    ?? (canZoomIn: false, canZoomOut: false)
                Button {
                    gridProxy.zoomIn?()
                } label: {
                    Label(String(localized: "library.display_zoom_in"), systemImage: "plus.magnifyingglass")
                }
                .disabled(!availability.canZoomIn)

                Button {
                    gridProxy.zoomOut?()
                } label: {
                    Label(String(localized: "library.display_zoom_out"), systemImage: "minus.magnifyingglass")
                }
                .disabled(!availability.canZoomOut)

                Divider()

                Toggle(isOn: aspectRatioGridBinding) {
                    Label(String(localized: "library.display_aspect_grid"), systemImage: "aspectratio")
                }
                .disabled(gridProxy.contentModeState?().toggleAvailable == false)
            } label: {
                Label(String(localized: "library.display_options"), systemImage: "rectangle.grid.3x2")
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(refinement.isActive ? ProtonColor.primary : ProtonColor.textNorm)
        }
        .accessibilityLabel(String(localized: "library.options"))
        .accessibilityValue(
            refinement.isActive ? refinementSummary : String(localized: "library.filter_all")
        )
    }

    private var selectionOptionsMenu: some View {
        Menu {
            Button {
                toggleSelectedFavorites()
            } label: {
                Label(
                    selectedAllFavorited
                        ? String(localized: "viewer.remove_favorite_action")
                        : String(localized: "viewer.favorite_action"),
                    systemImage: selectedAllFavorited ? "heart.slash" : "heart"
                )
            }
            .disabled(selection.selected.isEmpty || selectionBusy)
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(String(localized: "selection.more_a11y"))
    }

    private var favoritesFilterBinding: Binding<Bool> {
        Binding(
            get: { refinement.favoritesOnly },
            set: { selected in
                updateRefinement { $0.favoritesOnly = selected }
            }
        )
    }

    private func mediaKindBinding(_ kind: TimelineRefinement.MediaKind) -> Binding<Bool> {
        Binding(
            get: { refinement.mediaKinds.contains(kind) },
            set: { selected in
                updateRefinement { refinement in
                    if selected {
                        refinement.mediaKinds.insert(kind)
                    } else {
                        refinement.mediaKinds.remove(kind)
                    }
                }
            }
        )
    }

    private func resetRefinement() {
        updateRefinement { $0 = .all }
    }

    private func updateRefinement(_ update: (inout TimelineRefinement) -> Void) {
        var next = refinement
        update(&next)
        guard next != refinement else { return }
        // A bounded Apple-style filter is a new reading surface, not a temporary replacement of the current
        // full-library viewport. Its newest result starts at top-leading. Clearing every filter returns to the
        // canonical full-library bottom-trailing edge through the fill-order transition below.
        refinementTopPlacementPending = next.isActive
        if !next.isActive {
            contentTransitionSignal &+= 1
        }
        refinement = next
    }

    private var aspectRatioGridBinding: Binding<Bool> {
        Binding(
            get: { displayMode == .aspectFitInsideSquare },
            set: { enabled in
                displayMode = enabled ? .aspectFitInsideSquare : .squareFillCrop
                gridProxy.setContentMode?(displayMode)
            }
        )
    }

    private var refinementSummary: String {
        var labels: [String] = []
        if refinement.favoritesOnly { labels.append(PhotoTag.favorites.title) }
        if refinement.mediaKinds.contains(.photo) {
            labels.append(String(localized: "library.filter_photos"))
        }
        if refinement.mediaKinds.contains(.video) { labels.append(PhotoTag.videos.title) }
        return ListFormatter.localizedString(byJoining: labels)
    }

    /// Localized center text for the shared selection-toolbar policy.
    private var selectionCenterText: String? {
        L10n.selectionCenterText(selectedCount: selection.selected.count)
    }

    private var selectedAllFavorited: Bool {
        !selection.selected.isEmpty && selection.selected.allSatisfy(model.favoriteUIDs.contains)
    }

    /// The grid keeps the last authoritative projection mounted while a newer query resolves. The expensive
    /// filter/flatten work runs once in TimelineCore, never synchronously from `body`.
    private var visibleItems: [PhotoItem] {
        guard hasProjectionCriteria else { return model.items }
        return (resolvedSearchProjection ?? searchProjection)?.presentationItems ?? model.items
    }

    private var usesTopLeadingProjection: Bool {
        hasSearchQuery || refinement.isActive
    }

    /// Separates full-library and projected identities by parity. The UIKit host can then distinguish a real
    /// content replacement from selection, toolbar and presentation updates without scanning every photo UID.
    private var visibleContentRevision: UInt64 {
        if hasProjectionCriteria, let projection = resolvedSearchProjection ?? searchProjection {
            return projection.revision &* 2 &+ 1
        }
        return model.timelineRevision &* 2
    }

    private var showsSearchLanding: Bool {
        surface == .search && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private var content: some View {
        let visibleItems = self.visibleItems
        ZStack(alignment: .topLeading) {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            if let feed = model.thumbnailFeed, !visibleItems.isEmpty {
                UIKitTimelineGrid(
                    items: visibleItems,
                    contentRevision: visibleContentRevision,
                    thumbnailFeed: feed,
                    metadataProvider: model.backend,
                    fillOrder: usesTopLeadingProjection ? .topLeading : .newestBottomTrailing,
                    initialViewportPlacement: usesTopLeadingProjection ? .oldest : .automatic,
                    displayMode: displayMode,
                    selectionMode: selection.isSelecting,
                    selectedUIDs: selection.selected,
                    isActive: isActive && !showsSearchLanding,
                    scrollToLatestSignal: scrollToLatestSignal,
                    scrollToTopSignal: refinementTopPlacementSignal,
                    proxy: gridProxy,
                    restoreScrollAnchor: projectionRestoreAnchor,
                    restoreScrollSignal: projectionRestoreSignal,
                    contentTransitionSignal: contentTransitionSignal,
                    prefersReducedMotion: reduceMotion,
                    onFirstContentReady: { withAnimation(.spring(duration: 0.55)) { model.markFirstContentReady() } },
                    onOpenPhoto: open,
                    onBeginSelection: selection.begin,
                    onToggleSelection: selection.toggle,
                    onDragSelectionChanged: selection.applyDragSelection
                )
                // Extend the scroll surface below the floating navigation and tab bars. The UIKit grid keeps
                // its safe-area content inset, so only the newest edge exposes protected space below the final
                // row; as soon as the user scrolls away, thumbnails move naturally beneath Liquid Glass.
                .ignoresSafeArea(.container, edges: [.top, .horizontal, .bottom])
                .allowsHitTesting(launchChromeVisible && !showsLibraryLoadingCover && !showsSearchLanding)
                .accessibilityHidden(!launchChromeVisible || showsLibraryLoadingCover)
                .accessibilityHidden(showsSearchLanding)
                .opacity(showsSearchLanding ? 0 : 1)
            }

            if showsSearchLanding {
                MobileSearchLandingScreen(
                    history: searchHistory,
                    suggestions: searchSuggestions,
                    recentRepresentatives: searchRecentRepresentatives,
                    onSelectQuery: onSelectSearchQuery,
                    onClearHistory: onClearSearchHistory
                )
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsSearchLanding)
        // Paint status over the resolved content bounds so flexible overlays remain centered.
        .overlay { overlay }
        .overlay(alignment: .top) { TopFrostBar(height: topFrostHeight) }
        .task(id: verticalSizeClass) {
            // Wait until UIKit has committed the new safe-area insets for a rotation before sizing the frost.
            await Task.yield()
            topFrostHeight = mobileTopBarFrostHeight()
        }
    }

    private var showsLibraryLoadingCover: Bool {
        guard !isProjectionPending, model.loadState.isLoading else { return false }
        return networkMonitor.isOnline || !model.items.isEmpty
    }

    @ViewBuilder private var overlay: some View {
        if !showsSearchLanding {
            ZStack {
                if isProjectionPending {
                    LoadingMark()
                        .frame(width: 64, height: 64)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ProtonColor.backgroundNorm)
                        .transition(.opacity)
                } else if !networkMonitor.isOnline && model.items.isEmpty
                    && (model.loadState.isLoading || model.loadState.failure != nil)
                {
                    OfflineContentUnavailableView()
                } else if model.loadState.isEmpty {
                    MobileEmptyLibraryView()
                } else if let failure = model.loadState.failure {
                    MobileLibraryErrorView(message: failure.message, retryable: failure.retryable) {
                        Task { await model.retry() }
                    }
                } else if isEmptySearchResult {
                    // Same empty-search treatment as the macOS timeline.
                    ContentUnavailableView.search(text: committedSearchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isEmptyRefinementResult {
                    ContentUnavailableView {
                        Label(
                            String(localized: "library.filter_empty_title"),
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    } description: {
                        Text(String(localized: "library.filter_empty_description"))
                    } actions: {
                        Button(String(localized: "library.filter_remove")) {
                            resetRefinement()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func open(_ item: PhotoItem) {
        if !hasProjectionCriteria {
            guard let index = model.index(of: item.uid) else { return }  // O(1), not an O(n) firstIndex scan
            viewerRouter.presentation = MobileViewerPresentation(
                index: index, items: model.items, context: ViewerCollectionContext(filter: .all)
            )
        } else {
            // While searching, the viewer pages through the filtered result set to match macOS.
            let items = visibleItems
            guard let index = items.firstIndex(where: { $0.uid == item.uid }) else { return }
            viewerRouter.presentation = MobileViewerPresentation(
                index: index, items: items, context: ViewerCollectionContext(filter: .all)
            )
        }
    }

    private var normalizedCommittedSearchText: String {
        committedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSearchQuery: Bool {
        !TimelineSearchQuery(normalizedCommittedSearchText).isEmpty
    }

    private var hasProjectionCriteria: Bool {
        hasSearchQuery || refinement.isActive
    }

    private var isCommittedSemanticSearchPending: Bool {
        semanticQuery?.requestedQuery == normalizedCommittedSearchText
            && semanticQuery?.isSearching == true
    }

    private var committedSemanticMatches: Set<PhotoUID>? {
        guard semanticQuery?.resolvedQuery == normalizedCommittedSearchText else { return nil }
        return semanticQuery?.rankedUIDs.map(Set.init)
    }

    private var searchKey: TimelineSearchProjectionKey {
        TimelineSearchProjectionKey(
            sourceRevision: model.timelineRevision,
            query: normalizedCommittedSearchText,
            context: TimelineSearchContext(favoriteUIDs: model.favoriteUIDs),
            semanticMatches: committedSemanticMatches,
            refinement: refinement
        )
    }

    private var searchProjectionRequest: TimelineSearchProjectionKey? {
        guard hasProjectionCriteria, !isCommittedSemanticSearchPending else { return nil }
        return searchKey
    }

    private var resolvedSearchProjection: TimelineSearchProjection? {
        guard hasProjectionCriteria, searchProjection?.key == searchKey else { return nil }
        return searchProjection
    }

    private var isProjectionPending: Bool {
        hasProjectionCriteria && (isCommittedSemanticSearchPending || resolvedSearchProjection == nil)
    }

    private var isSearchResultPending: Bool {
        hasSearchQuery && isProjectionPending
    }

    private var isEmptySearchResult: Bool {
        hasSearchQuery && !isSearchResultPending && resolvedSearchProjection?.snapshot.isEmpty == true
    }

    private var isEmptyRefinementResult: Bool {
        !hasSearchQuery
            && refinement.isActive
            && !isProjectionPending
            && resolvedSearchProjection?.snapshot.isEmpty == true
    }

    private func resolveSearchProjection() async {
        guard let key = searchProjectionRequest else { return }
        let sections = model.sections
        guard let projection = await searchCoordinator.resolve(sections: sections, key: key),
            !Task.isCancelled,
            searchProjectionRequest == key
        else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            searchProjection = projection
            contentTransitionSignal &+= 1
            if refinementTopPlacementPending, key.refinement == refinement {
                refinementTopPlacementPending = false
                refinementTopPlacementSignal &+= 1
            }
        }
    }

    /// Debounced search commit - the exact macOS pipeline: the semantic coordinator sees every
    /// keystroke (it debounces internally and discards stale epochs), while the committed
    /// lexical query updates after a short pause so the grid never refilters per keystroke.
    private func scheduleSearchCommit(_ value: String) {
        searchDebounceTask?.cancel()
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedValue.isEmpty {
            if searchSessionActive {
                searchSessionActive = false
                projectionRestoreAnchor = searchReturnAnchor
                projectionRestoreSignal &+= 1
            }
        } else if !searchSessionActive {
            // Capture before the debounced query replaces the library projection. Clearing the native search
            // field can then restore the exact photo and sub-row offset the user was looking at.
            searchReturnAnchor = gridProxy.currentScrollAnchor?()
            searchSessionActive = true
        }
        if let smartSearch = model.smartSearch {
            let lifecycle = smartSearch.lifecycleActor
            if semanticQueryLifecycle != ObjectIdentifier(lifecycle) {
                // Bind the coordinator to the lifecycle for this session.
                semanticQuery = MLSmartSearchQueryCoordinator(
                    lifecycle: lifecycle,
                    initialScope: searchScope
                )
                semanticQueryLifecycle = ObjectIdentifier(lifecycle)
            }
        } else {
            semanticQuery = nil
            semanticQueryLifecycle = nil
        }
        semanticQuery?.update(query: value)
        if normalizedValue.isEmpty {
            committedSearchText = ""
            searchDebounceTask = nil
            return
        }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            committedSearchText = value
            searchDebounceTask = nil
        }
    }

    private func startShare() {
        guard let backend = model.backend else { return }
        let chosen = model.selectedItems(selection.selected)  // O(k log k), not an O(n) filter
        selection.startShare(items: chosen, backend: backend)
    }

    private func toggleSelectedFavorites() {
        selection.performFavorite { uids in
            await model.toggleFavorite(uids)
        }
    }

    private func performTrash() {
        selection.performTrash { try await model.trashItems($0) }
    }
}

/// Identifiable payload for the viewer sheet - the full item list plus the tapped index, so the viewer can page.
struct MobileViewerPresentation: Identifiable {
    let id = UUID()
    let index: Int
    let items: [PhotoItem]
    let context: ViewerCollectionContext
}

/// A successful viewer mutation removes the current item from the collection that opened it. Filtered grids
/// own their local snapshot, so this tiny presentation event lets them reconcile immediately without a second
/// server fetch or a whole-library scan on the main actor.
struct MobileViewerMutation: Equatable {
    let id = UUID()
    let uid: PhotoUID
}

/// App-wide viewer presentation state, owned above the size-class-adaptive shell. Screens write
/// `presentation`; the single `fullScreenCover` lives in `MobileMainTabView`, so a live iPad window resize
/// may change the underlying shell without dismissing open media.
@MainActor @Observable final class MobileViewerRouter {
    var presentation: MobileViewerPresentation?
    private(set) var completedMutation: MobileViewerMutation?

    func noteCompletedMutation(uid: PhotoUID) {
        completedMutation = MobileViewerMutation(uid: uid)
    }
}

/// Frost height uses the key-window top inset plus the inline navigation-bar height.
///
/// Read the inset after layout settles; initialization-time reads can trigger a SwiftUI layout cycle under
/// full-bleed overlays.
let mobileTopBarFrostHeightDefault: CGFloat = 91

func mobileTopBarFrostHeight() -> CGFloat {
    let topSafeArea =
        UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)?
        .safeAreaInsets.top ?? 47
    return topSafeArea + 44
}
