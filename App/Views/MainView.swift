import AlbumCore
import AlbumsFeature
import AppKit
import CoreLocation
import DesignSystem
import DesignSystemCore
import GridCore
import MLSearchCore
import MLSearchFeature
import MapFeature
import MediaByteCache
import MediaCache
import MediaLocationCore
import PhotoViewerFeature
import PhotosCore
import ProtonDriveBackend
import SwiftUI
import TimelineCore
import TimelineFeature
import UniformTypeIdentifiers
import UploadCore
import UploadFeature

struct MainView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let model: AppModel
    let facade: ProtonClientFacade
    let backend: any PhotosBackend
    @Bindable var uploadCoordinator: UploadCoordinator

    @State private var timelineModel: TimelineViewModel
    @State private var mapClusterModel: TimelineViewModel
    @State private var viewerModel: PhotoViewerModel?
    @State private var level: Int = 3  // 0 is largest; 5 is the densest overview.
    @State private var temporalMode: TimelineTemporalMode = .allPhotos
    @State private var temporalProjection = TimelineTemporalProjection.loading(mode: .years)
    @State private var focusedTemporalYear: Int?
    // Levels L0-L3 use this content mode. Overview levels always crop to a square.
    @State private var gridContentMode: TileContentDisplayMode = .aspectFitInsideSquare

    /// Suspends the title-bar frost while the Metal surface is being scaled during resize.
    @State private var gridLiveResizeActive = false
    @State private var sidebarOpen: Bool
    @State private var sidebarWidth: CGFloat
    @State private var columnVisibility: NavigationSplitViewVisibility  // native sidebar show/hide
    @State private var restoredInitialSidebarVisibility = false
    private let initiallyShowsSidebar: Bool
    @State private var albums: [AlbumSummary] = []
    @State private var albumCatalogFailed = false
    @State private var albumLoadGeneration: UInt64 = 0
    @State private var albumActions: AlbumActionCoordinator
    @State private var showCreateAlbum = false
    @State private var showAlbumDestination = false
    @State private var selection: PhotoFilter = .all
    @State private var mapClusterPresentation: MapClusterPresentation?
    @State private var mapClusterPageIndex = 0
    @State private var mapClusterRouteGeneration = 0
    @State private var routeScrollGeneration = 0
    /// Stores a layout-independent photo anchor for each visited route.
    /// Routes without an anchor open at the newest photo.
    @State private var routeScrollPositions: [PhotoFilter: GridScrollAnchor<PhotoUID>] = [:]
    /// Holds the initial anchor for the current route generation.
    /// Route changes set it before loading sections.
    @State private var routeInitialScrollAnchor: GridScrollAnchor<PhotoUID>? = nil
    @State private var searchText = ""
    @State private var committedSearchText = ""
    /// Debounced, epoch-guarded semantic query pipeline (shared Core). Created once Smart Search
    /// is configured; publishes ranked UIDs the timeline widens its lexical results with.
    @State private var semanticQuery: MLSmartSearchQueryCoordinator?
    @State private var searchScope: MLSearchScope = .all
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchHistory = TimelineSearchHistory()
    @State private var searchSuggestions: [TimelineSearchSuggestion] = []
    // Shared-element transition between a photo and its grid cell.
    @State private var gridProxy = GridProxy<PhotoUID>()
    @State private var mapClusterGridProxy = GridProxy<PhotoUID>()
    /// The timeline content revision whose visible frame the Metal host has fully drawn. The shared load-state
    /// policy may present a non-empty cached revision while Proton validation continues in the background.
    @State private var renderedLibraryRevision: UInt64?
    @State private var veilSettleTask: Task<Void, Never>?
    @State private var zoom: ZoomTransition?
    // Real height of the native window toolbar (its top safe-area inset). The viewer lays its media out
    // below this, so the open/close zoom must fly the photo into the SAME region to avoid a shrink/jump.
    @State private var topBarInset: CGFloat = 0
    @State private var networkMonitor = NetworkMonitor.shared
    // The floating sidebar width is the grid's leading obstruction. Keep it stable during resize so geometry
    // is not recomputed per frame.
    private var leadingObstructionInset: CGFloat { columnVisibility == .detailOnly ? 0 : sidebarWidth }
    // Selection + export.
    @State private var selectionMode = false
    @State private var selectedUIDs: Set<PhotoUID> = []
    @State private var isExporting = false
    /// 0…1 download progress for the top-bar ring (blended across all selected items).
    @State private var exportFraction: Double = 0
    /// The running export, so the progress menu can cancel it mid-download (partial ZIP is discarded).
    @State private var exportTask: Task<Void, Never>?
    @State private var confirmLargeExport = false
    @State private var pendingExportItems: [PhotoItem] = []
    @State private var pendingExportZipName: String?
    /// Above this many selected items, downloading a ZIP asks for confirmation first.
    private let largeExportThreshold = 50
    @State private var pendingTrashItems: [PhotoItem] = []
    @State private var closeViewerAfterTrash = false
    @State private var confirmTrash = false
    @State private var confirmAlbumPhotoAction = false
    @State private var confirmEmptyTrash = false
    @State private var isTrashMutating = false
    @State private var isEmptyingTrash = false
    @State private var confirmDeleteAlbum = false
    @State private var isDeletingAlbum = false
    @State private var albumDeleteFailureMessage: String?
    @State private var albumCoverFailureMessage: String?
    @State private var isSettingAlbumCover = false
    @State private var exportFailureTitle: String?
    @State private var exportFailureMessage: String?
    /// Set when a trash/restore API call fails. Local projections change only after server success, so a
    /// failed request never needs to reconstruct optimistic state or risks showing a false success.
    @State private var trashActionFailureMessage: String?
    @State private var albumMembershipFailureMessage: String?
    // Favorites (read from server so iOS favorites show up; toggle writes back).
    @State private var favorites: Set<PhotoUID> = []
    @State private var uploadRefreshTask: Task<Void, Never>?
    @State private var uploadRefreshGeneration: UInt64 = 0
    @State private var backupUploadRefreshCoordinator = TimelineUploadRefreshCoordinator()
    @State private var uploadRefreshMessage: String?
    @State private var uploadRefreshBusy = false
    /// Whether the current banner message represents success (drives the icon/colour). Tracked
    /// explicitly so the banner never compares against localized message text.
    @State private var uploadRefreshSuccess = false
    private let libraryChangeMonitor = LibraryChangeMonitor()
    private let feed: ThumbnailFeed
    private let temporalCoverImageLoader: TimelineTemporalCoverImageLoader
    private let zoomOpenSpring = (response: 0.34, damping: 0.86)
    private let zoomCloseSpring = (response: 0.32, damping: 0.88)

    init(model: AppModel, facade: ProtonClientFacade) {
        self.model = model
        self.facade = facade
        self.backend = facade.backend
        self.uploadCoordinator = facade.uploadCoordinator
        _albumActions = State(initialValue: AlbumActionCoordinator(repository: facade.albums))
        // Learned thumbnail dimensions persist into the library metadata DB (photos.w/h) through the
        // backend bridge - batched by the coalescer, so decode callbacks never touch the DB directly.
        let dimensions = PhotoDimensionCoalescer(store: backend)
        // Use the SHARED, account-configured cache (AppModel.prepareBackend calls
        // OfflineLibraryManager.shared.configure(session:) before this view is built) so the encrypted
        // disk cache uses the durable per-account session-derived key and survives relaunch. A fresh
        // ThumbnailCache() here would stay on a per-process ephemeral key and re-crawl the whole library
        // every launch.
        let feed = ThumbnailFeed(
            cache: OfflineLibraryManager.shared.cache,
            loader: facade.librarySources,
            dimensions: dimensions
        )
        self.feed = feed
        self.temporalCoverImageLoader = TimelineTemporalCoverImageLoader(
            media: backend,
            previewCache: OfflineLibraryManager.shared.previewCache,
            originalsCache: OfflineLibraryManager.shared.originalsCache
        )
        _timelineModel = State(initialValue: TimelineViewModel(repository: backend, feed: feed, library: backend))
        _mapClusterModel = State(initialValue: TimelineViewModel(repository: backend, feed: feed, library: backend))
        let sidebarVisible = SidebarPersistence.resolvedVisible()
        let width = SidebarPersistence.resolvedWidth()
        initiallyShowsSidebar = sidebarVisible
        // Always mount the native sidebar column once. Starting NavigationSplitView directly in `.detailOnly`
        // leaves AppKit's navigation toolbar item at x=22, underneath the traffic lights, until the first real
        // sidebar toggle. Restore the persisted visibility after the first rendered revision, while the launch
        // cover is still up, so AppKit establishes the native sidebar/titlebar geometry first.
        _sidebarOpen = State(initialValue: true)
        _sidebarWidth = State(initialValue: width)
        _columnVisibility = State(initialValue: .all)
    }

    var body: some View {
        ZStack {
            // NATIVE shell: NavigationSplitView gives the macOS-26 floating Liquid-Glass sidebar (native title,
            // toggle, glass to the top corner) for free. The detail's Metal grid extends UNDER the floating
            // sidebar via `.ignoresSafeArea(.container, edges: [.top, .leading])`, while its content is laid out
            // only in the unobscured area (the leading-obstruction inset = the detail's leading safe-area inset).
            synchronizedToolbar {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView(
                        albums: albums,
                        isLoadingAlbums: albumActions.showsInitialAlbumLoadingPlaceholder,
                        albumCatalogFailed: albumCatalogFailed,
                        sharedAlbums: albumActions.sharedAlbums,
                        isLoadingSharedAlbums: albumActions.showsInitialSharedAlbumLoadingPlaceholder,
                        sharedAlbumCatalogFailed: albumActions.sharedLoadErrorMessage != nil,
                        canLeaveSharedAlbum: albumActions.canLeaveSharedAlbum,
                        thumbnailFeed: feed,
                        sourceAnalysisRevision: model.sourceAnalysisRevision,
                        selection: $selection,
                        onRetryAlbums: { Task { await loadAlbums() } },
                        onRetrySharedAlbums: { Task { await albumActions.refreshSharedAlbums() } },
                        onLeaveSharedAlbum: { album in
                            Task { _ = await albumActions.leaveSharedAlbum(album) }
                        }
                    )
                    // Fixed width. (The OS still draws a resize cursor on the divider even though the column is not
                    // user-resizable - an AppKit quirk we accept; min==ideal==max did not change it.)
                    .navigationSplitViewColumnWidth(sidebarWidth)
                } detail: {
                    libraryDetail
                }
            }
            .task(id: model.albumCatalogRevision) { await loadAlbums() }
            .onAppear {
                attachOfflineManager()
                AppMemoryPressureCoordinator.shared.attachFeed(timelineModel.feed)
                gridProxy.onContentReady = { revision in
                    renderedLibraryRevision = revision
                    timelineModel.markInitialContentReady()
                    evaluateVeilLift()
                }
                gridProxy.liveResizeChanged = { @MainActor [state = self.$gridLiveResizeActive] active in
                    state.wrappedValue = active
                }
                evaluateVeilLift()
            }
            .onChange(of: librarySettled) { _, _ in evaluateVeilLift() }
            .onChange(of: timelineModel.contentRevision) { _, _ in evaluateVeilLift() }
            .task(id: timelineModel.contentRevision) {
                let sections = currentTimelineSections
                let resolved = await Task.detached(priority: .utility) {
                    TimelineSearchDiscovery.recentDateSuggestions(sections: sections)
                }.value
                guard !Task.isCancelled else { return }
                searchSuggestions = resolved
            }
            .task(id: temporalProjectionRequestID) {
                await rebuildTemporalProjection()
            }
            .onChange(of: uploadRefreshBusy) { _, _ in evaluateVeilLift() }
            .onChange(of: selection) { oldValue, newValue in
                selectionMode = false
                selectedUIDs.removeAll()
                if newValue != .all {
                    temporalMode = .allPhotos
                    focusedTemporalYear = nil
                }
                if newValue != .map {
                    mapClusterPresentation = nil
                }
                // Switching sidebar route while a photo/video is open: close the viewer INSTANTLY so the new tab's
                // grid (or Map) just shows. No zoom-back-to-cell - the photo's cell usually isn't in the new
                // route, and the expectation is simply "tab switches, photo closes."
                if viewerModel != nil {
                    zoom = nil
                    viewerModel = nil
                }
                // Remember where the user was in the route they're leaving (the grid still shows it at this
                // point, so the proxy reports the OLD route's anchor). Returning to that route re-pins it.
                if let anchor = gridProxy.currentScrollAnchor?() {
                    routeScrollPositions[oldValue] = anchor
                }
                // Non-timeline routes (for example the Map overlay) keep the last grid route underneath.
                guard newValue.hasTimeline else { return }
                // Set the route anchor and generation before loading route data. The host consumes the one-shot
                // placement when geometry is valid.
                routeInitialScrollAnchor = routeScrollPositions[newValue]
                routeScrollGeneration += 1
                Task { await timelineModel.select(newValue) }
            }
            .onChange(of: timelineModel.wholeLibraryContentRevision) { _, _ in
                let items = timelineModel.wholeLibraryItemsForViewer
                OfflineLibraryManager.shared.liveAssetCount = items.count
                // Kick off the low-priority GPS crawl (once) so the Map's location index fills in behind the
                // thumbnail crawl.
                OfflineLibraryManager.shared.startLocationCrawl(items: items, metadata: backend)
                // New/removed assets flow into the Smart Search index on its next background pass.
                model.updateSmartSearchAssets(
                    items,
                    authority: timelineModel.wholeLibraryInventoryAuthority
                )
            }
            .onChange(of: timelineModel.wholeLibraryInventoryAuthorityRevision) { _, _ in
                model.updateSmartSearchAssets(
                    timelineModel.wholeLibraryItemsForViewer,
                    authority: timelineModel.wholeLibraryInventoryAuthority
                )
            }
            .onDisappear(perform: handleDisappear)
            .onChange(of: columnVisibility) { _, newValue in
                // The NATIVE split-view toggle drives columnVisibility - mirror it back into our open-state +
                // persistence (the ⌥⌘S path goes through toggleSidebar() which sets both).
                let visible = newValue != .detailOnly
                guard visible != sidebarOpen else { return }
                sidebarOpen = visible
                SidebarPersistence.saveVisible(visible)
            }
            .onReceive(NotificationCenter.default.publisher(for: .encryptedMemoriesToggleSidebar)) { _ in
                toggleSidebar()
            }
            .onChange(of: networkMonitor.didRecentlyRestoreConnection) { _, restored in
                if restored {
                    retryAfterConnectivityRestored()
                }
            }
            .task { await uploadCoordinator.start() }
            .task { await startLibraryChangeMonitor() }
            .onReceive(NotificationCenter.default.publisher(for: .encryptedMemoriesUploadPhotos)) { notification in
                performUploadUIAction("uploadPhotos", trigger: uploadTrigger(from: notification))
            }
            .onReceive(NotificationCenter.default.publisher(for: .encryptedMemoriesUploadFolder)) { notification in
                performUploadUIAction("uploadFolder", trigger: uploadTrigger(from: notification))
            }
            .onReceive(NotificationCenter.default.publisher(for: .encryptedMemoriesShowUploadQueue)) { notification in
                performUploadUIAction("showQueue", trigger: uploadTrigger(from: notification))
            }
            .onReceive(NotificationCenter.default.publisher(for: .encryptedMemoriesRefreshLibrary)) { _ in
                refreshLibraryManually()
            }
            .onChange(of: uploadCoordinator.completedUploadRevision) { _, _ in
                guard let completed = uploadCoordinator.latestCompletedUpload else { return }
                scheduleUploadRefresh(completed)
            }
            .onChange(of: model.photoBackupController?.uploadedLibraryMutationRevision) { _, _ in
                scheduleLibraryRefreshAfterBackupUpload()
            }
            .sheet(isPresented: $uploadCoordinator.isDestinationSheetPresented) {
                UploadDestinationSheet(coordinator: uploadCoordinator)
            }

            // Library Map route. Match the other library routes with a plain unavailable surface until the
            // location index contains a place; rendering an empty world map only adds visual noise.
            if selection == .map {
                let locationIndex = OfflineLibraryManager.shared.locationIndex
                Group {
                    if locationIndex.coordinates.isEmpty {
                        mapEmptyState
                    } else {
                        LibraryMapScreen(
                            index: locationIndex,
                            thumbnail: { feed.memoryImage(for: $0) },
                            loadThumbnail: { await feed.cachedImage(for: $0) },
                            onSelectPhoto: { openPhotoByUID($0) },
                            onSelectCluster: { uids, coordinate in showMapCluster(uids: uids, coordinate: coordinate) })
                    }
                }
                .padding(.leading, leadingObstructionInset)
                .animation(.easeInOut(duration: 0.3), value: leadingObstructionInset)
                .ignoresSafeArea()
            }

            if selection == .map, mapClusterPresentation != nil {
                TimelineView(
                    model: mapClusterModel,
                    level: $level,
                    gridProfile: TimelineGridProfiles.secondaryCollectionProfile,
                    gridFillOrder: .topLeading,
                    initialViewportPlacement: .oldest,
                    proxy: mapClusterGridProxy,
                    routeScrollGeneration: mapClusterRouteGeneration,
                    routeInitialScrollAnchor: nil,
                    searchText: committedSearchText,
                    isSearchPending: isCommittedSemanticSearchPending,
                    semanticMatches: committedSemanticMatches,
                    selectionMode: selectionMode,
                    media: backend,
                    metadataProvider: backend,
                    favoriteUIDs: favorites,
                    isOffline: !networkMonitor.isOnline,
                    onSelectionChange: { selectedUIDs = $0 }
                ) { item, items in
                    openPhoto(item, items, proxy: mapClusterGridProxy)
                }
                // This root-ZStack sibling sits above the NavigationSplitView, unlike its detail-hosted primary
                // grid. Move the whole surface beside the floating sidebar and keep the Metal host's local
                // obstruction at zero so the sidebar is neither covered nor applied twice.
                .padding(.leading, leadingObstructionInset)
                .animation(.easeInOut(duration: 0.3), value: leadingObstructionInset)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .environment(\.gridTopBarInset, topBarInset)
                .transition(.opacity)
            }

            // Keep the viewer mounted during interactive dismissal so its pinch gesture remains active.
            if let viewerModel, zoom == nil || zoom?.interactive == true {
                PhotoViewerView(
                    model: viewerModel,
                    isFavorite: { favorites.contains($0) },
                    onToggleFavorite: toggleFavorite,
                    onClose: { closePhoto() },
                    onPinchDismissBegan: beginInteractiveDismiss,
                    onPinchDismissChanged: updateInteractiveDismiss,
                    onPinchDismissEnded: { endInteractiveDismiss(shouldClose: $0) },
                    isDismissing: zoom?.interactive == true
                )
                // Keep the viewer beside the floating sidebar. The inset matches the zoom overlay's content rect.
                .padding(.leading, leadingObstructionInset)
                .animation(.easeInOut(duration: 0.3), value: leadingObstructionInset)  // slide with the sidebar toggle
                // Do not hide the view with opacity while dismissing. Keep it hit-testable so the gesture cannot
                // reach the grid behind it.
            }

            // Shared-element zoom overlay: a single image morphing between the cell and fullscreen.
            if let zoom { zoomOverlay(zoom) }

            uploadRefreshBanner
        }
        .background(
            // Reads the real top safe-area inset (= native toolbar height) so the zoom transition and the
            // viewer agree on exactly where the media sits below the opaque top bar.
            GeometryReader { geo in
                Color.clear
                    .onAppear { topBarInset = geo.safeAreaInsets.top }
                    .onChange(of: geo.safeAreaInsets.top) { _, new in topBarInset = new }
            }
        )
        .coordinateSpace(name: "root")
        .animation(.easeInOut(duration: 0.22), value: sidebarOpen)
        .sheet(isPresented: $showCreateAlbum) {
            AlbumCreationSheet(
                coordinator: albumActions,
                onAlbumsChanged: { Task { await loadAlbums() } },
                onCompleted: { _ in showCreateAlbum = false }
            )
        }
        .alert(trashConfirmationTitle, isPresented: $confirmTrash) {
            Button("alert.move_to_trash", role: .destructive) {
                let items = pendingTrashItems
                let shouldClose = closeViewerAfterTrash
                pendingTrashItems = []
                closeViewerAfterTrash = false
                trashPhotos(items, closeViewer: shouldClose)
            }
            Button(L10n.string("action.cancel"), role: .cancel) {
                pendingTrashItems = []
                closeViewerAfterTrash = false
            }
        } message: {
            Text(trashConfirmationMessage)
        }
        .confirmationDialog(
            L10n.string("albums.remove_photos_title"),
            isPresented: $confirmAlbumPhotoAction,
            titleVisibility: .visible
        ) {
            Button(L10n.string("albums.remove_photos_action")) { removeSelectedFromCurrentAlbum() }
            Button(L10n.string("albums.move_photos_to_trash"), role: .destructive) { trashSelected() }
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("albums.remove_photos_message"))
        }
        .alert(L10n.string("trash.empty_title"), isPresented: $confirmEmptyTrash) {
            Button(L10n.string("trash.empty_confirm"), role: .destructive) {
                emptyTrash()
            }
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("trash.empty_message"))
        }
        .alert(L10n.string("albums.delete_title"), isPresented: $confirmDeleteAlbum) {
            Button(L10n.string("albums.delete_action"), role: .destructive) { deleteCurrentAlbum() }
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("albums.delete_message"))
        }
        .alert("export.confirm_many_title", isPresented: $confirmLargeExport) {
            Button("export.confirm_many_button") {
                let items = pendingExportItems
                let zipName = pendingExportZipName
                pendingExportItems = []
                pendingExportZipName = nil
                startExport(items, zipSuggestedName: zipName)
            }
            Button(L10n.string("action.cancel"), role: .cancel) {
                pendingExportItems = []
                pendingExportZipName = nil
            }
        } message: {
            Text("export.confirm_many_message \(pendingExportItems.count)")
        }
        .alert(
            "alert.trash_action_failed_title",
            isPresented: Binding(
                get: { trashActionFailureMessage != nil },
                set: { if !$0 { trashActionFailureMessage = nil } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) { trashActionFailureMessage = nil }
        } message: {
            Text(trashActionFailureMessage ?? "")
        }
        .alert(
            L10n.string("albums.remove_photos_failed_title"),
            isPresented: Binding(
                get: { albumMembershipFailureMessage != nil },
                set: { if !$0 { albumMembershipFailureMessage = nil } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) { albumMembershipFailureMessage = nil }
        } message: {
            Text(albumMembershipFailureMessage ?? "")
        }
        .alert(
            L10n.string("albums.delete_failed_title"),
            isPresented: Binding(
                get: { albumDeleteFailureMessage != nil },
                set: { if !$0 { albumDeleteFailureMessage = nil } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) { albumDeleteFailureMessage = nil }
        } message: {
            Text(albumDeleteFailureMessage ?? "")
        }
        .alert(
            "albums.cover_failed_title",
            isPresented: Binding(
                get: { albumCoverFailureMessage != nil },
                set: { if !$0 { albumCoverFailureMessage = nil } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) { albumCoverFailureMessage = nil }
        } message: {
            Text(albumCoverFailureMessage ?? "")
        }
        .alert(
            albumActions.actionFailure?.title ?? "",
            isPresented: Binding(
                get: { albumActions.actionFailure != nil },
                set: { if !$0 { albumActions.clearActionFailure() } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) {
                albumActions.clearActionFailure()
            }
        } message: {
            Text(albumActions.actionFailure?.message ?? "")
        }
        .alert(
            Text(exportFailureTitle ?? ""),
            isPresented: Binding(
                get: { exportFailureMessage != nil },
                set: {
                    if !$0 {
                        exportFailureTitle = nil
                        exportFailureMessage = nil
                    }
                }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) {
                exportFailureTitle = nil
                exportFailureMessage = nil
            }
        } message: {
            Text(exportFailureMessage ?? "")
        }
    }

    private func handleDisappear() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        cancelVeilTasks()
        let backupRefresh = backupUploadRefreshCoordinator
        Task { await backupRefresh.cancel() }
        let changeMonitor = libraryChangeMonitor
        Task { await changeMonitor.stop() }
    }

    private var libraryDetail: some View {
        Group {
            if showsTemporalBrowser {
                TimelineTemporalBrowser(
                    projection: temporalProjection,
                    thumbnailFeed: feed,
                    coverImageLoader: temporalCoverImageLoader,
                    focusedYear: focusedTemporalYear,
                    onSelectYear: selectTemporalYear,
                    onOpenPhotos: { item, items in openPhoto(item, items, proxy: nil) }
                )
                // The temporal browser is a SwiftUI surface rather than the Metal grid, so it must consume the
                // floating sidebar obstruction explicitly. Keep its visible content and hit targets beside the
                // sidebar while the shared root still extends beneath the native title bar.
                .padding(.leading, leadingObstructionInset)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: leadingObstructionInset)
                .transition(.opacity)
            } else {
                TimelineView(
                    model: timelineModel,
                    level: $level,
                    gridFillOrder: gridFillOrder,
                    proxy: gridProxy,
                    routeScrollGeneration: routeScrollGeneration,
                    routeInitialScrollAnchor: routeInitialScrollAnchor,
                    searchText: committedSearchText,
                    isSearchPending: isCommittedSemanticSearchPending,
                    semanticMatches: committedSemanticMatches,
                    selectionMode: selectionMode,
                    media: backend,
                    metadataProvider: backend,
                    favoriteUIDs: favorites,
                    isOffline: !networkMonitor.isOnline,
                    onSelectionChange: { selectedUIDs = $0 },
                    onOpen: { item, items in openPhoto(item, items, proxy: nil) }
                )
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: temporalMode)
        .ignoresSafeArea(.container, edges: [.top, .leading])
        .overlay(alignment: .top) {
            if viewerModel == nil {
                TopFrostBar(height: topBarInset + 12)
                    .opacity(gridLiveResizeActive ? 0 : 1)
                    .animation(.easeInOut(duration: 0.12), value: gridLiveResizeActive)
            }
        }
        .navigationTitle(viewerModel == nil ? title : "")
        .smartSearchToolbar(
            text: $searchText,
            scope: $searchScope,
            availableScopes: model.smartSearch?.availableSearchScopes ?? [.all],
            isEnabled: model.smartSearch?.snapshot.isSearchAvailable == true,
            isVisible: viewerModel == nil,
            placement: .toolbar,
            prompt: Text(L10n.string("search.prompt \(title)")),
            recentSearches: searchHistory.queries,
            suggestions: searchSuggestions.map {
                SmartSearchSuggestionItem(id: $0.id, title: $0.title, query: $0.query)
            },
            onClearRecentSearches: clearSearchHistory
        )
        .onSubmit(of: .search) { recordSearchHistory(searchText) }
        .onChange(of: searchScope) { _, scope in semanticQuery?.setScope(scope) }
        // Keep the native Liquid Glass toolbar. The real insets keep grid and viewer geometry aligned.
        .environment(\.gridLeadingEventInset, leadingObstructionInset)
        .environment(\.gridTopBarInset, topBarInset)
        .onChange(of: searchText) { _, value in scheduleSearchCommit(value) }
    }

    /// Native upload menu for the system toolbar.
    private var uploadToolbarMenu: some View {
        Menu {
            Button("menu.upload_photos") { performUploadUIAction("uploadPhotos", trigger: .toolbar) }
                .disabled(!uploadCoordinator.uploadCapabilities.canUpload)
            Button("menu.upload_folder") { performUploadUIAction("uploadFolder", trigger: .toolbar) }
                .disabled(!uploadCoordinator.uploadCapabilities.canUpload)
            Divider()
            Button("menu.show_uploads") { performUploadUIAction("showQueue", trigger: .toolbar) }
        } label: {
            Label("toolbar.upload", systemImage: "tray.and.arrow.up")
        }
        .help("toolbar.upload_menu_help")
        .accessibilityLabel("toolbar.upload")
        .popover(isPresented: $uploadCoordinator.isQueueVisible, arrowEdge: .top) {
            UploadQueuePanel(coordinator: uploadCoordinator)
        }
    }

    /// Native toolbar menu for actions on the selected album.
    private var albumActionsToolbarMenu: some View {
        Menu {
            Button(selectionMode ? L10n.string("action.done") : L10n.string("action.select")) {
                selectionMode.toggle()
                if !selectionMode { selectedUIDs.removeAll() }
            }
            Divider()
            Button(L10n.string("albums.delete_action"), role: .destructive) {
                confirmDeleteAlbum = true
            }
            .disabled(isDeletingAlbum || !facade.albums.capabilities.canDelete)
        } label: {
            Label(L10n.string("albums.more_actions"), systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .help(L10n.string("albums.more_actions"))
        .accessibilityLabel(L10n.string("albums.more_actions"))
    }

    /// Keeps album creation available independently of the current selection.
    private var createAlbumToolbarMenu: some View {
        Menu {
            Button {
                showCreateAlbum = true
            } label: {
                Label(L10n.string("albums.create_title"), systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(!albumActions.canCreate)
        } label: {
            Label(L10n.string("albums.create_title"), systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .help(L10n.string("albums.create_title"))
        .accessibilityLabel(L10n.string("albums.create_title"))
    }

    /// Reuses one toolbar region for download progress or the Trash restore action.
    @ViewBuilder private var downloadActionItem: some View {
        if isExporting {
            exportProgressIndicator
            exportCancelButton
        } else if selection == .trash {
            Button {
                restoreSelected()
            } label: {
                if selectedUIDs.isEmpty {
                    Image(systemName: "arrow.uturn.backward")
                } else {
                    Label("\(selectedUIDs.count)", systemImage: "arrow.uturn.backward")
                }
            }
            .disabled(selectedUIDs.isEmpty || isTrashMutating)
            .help("toolbar.restore_from_trash")
            .accessibilityLabel(
                selectedUIDs.isEmpty
                    ? "a11y.restore_selected_from_trash" : "a11y.restore_count_from_trash \(selectedUIDs.count)")
        } else {
            Button {
                downloadSelected()
            } label: {
                if selectedUIDs.isEmpty {
                    Image(systemName: "square.and.arrow.down")
                } else {
                    Label("\(selectedUIDs.count)", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(selectedUIDs.isEmpty)
            .help(
                selectedUIDs.count > 1
                    ? "toolbar.download_count_photos_help \(selectedUIDs.count)" : "toolbar.download_original"
            )
            .accessibilityLabel(
                selectedUIDs.isEmpty
                    ? "a11y.download_selected_originals"
                    : "a11y.download_count_selected_originals \(selectedUIDs.count)")
        }
    }

    /// Native determinate progress paired with a separate cancellation control.
    private var exportProgressIndicator: some View {
        let pct = Int((exportFraction * 100).rounded())
        return ProgressView(value: max(0.001, min(1, exportFraction)))
            .progressViewStyle(.circular)
            .controlSize(.regular)
            .scaleEffect(0.6)
            .help("export.progress_percent \(pct)")
            .accessibilityLabel("export.progress_percent \(pct)")
    }

    private var exportCancelButton: some View {
        Button {
            cancelExport()
        } label: {
            Label("export.cancel", systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .help("export.cancel")
        .accessibilityLabel("export.cancel")
    }

    private var uploadRefreshBanner: some View {
        let connectivityState = LibraryConnectivityBannerState.resolve(
            isOnline: networkMonitor.isOnline,
            didRecentlyRestoreConnection: networkMonitor.didRecentlyRestoreConnection
        )
        let hasUploadMessage = uploadRefreshMessage != nil
        let backgroundVisible = backgroundLibraryActivityActive && viewerModel == nil && selection.hasTimeline
        let connectivityVisible = connectivityState != .hidden
        let message: String
        let visualState: LibraryActivityBannerState
        switch connectivityState {
        case .offline:
            message = L10n.string("library.title_offline")
            visualState = .offline
        case .connectionRestored:
            message = L10n.string("library.title_online_restored")
            visualState = .success
        case .hidden:
            message = uploadRefreshMessage ?? "\(L10n.string("library.title_activity")) …"
            visualState =
                hasUploadMessage
                ? (uploadRefreshBusy ? .working : (uploadRefreshSuccess ? .success : .failure))
                : .working
        }
        return LibraryActivityBannerOverlay(
            isPresented: connectivityVisible || hasUploadMessage || backgroundVisible,
            message: message,
            state: visualState,
            leadingObstructionInset: leadingObstructionInset
        )
    }

    // MARK: - Zoom transition

    private struct MapClusterPresentation {
        let title: String
        let coordinate: CLLocationCoordinate2D
        let pager: PhotoLocationClusterPager
    }

    private struct ZoomTransition: Equatable {
        let item: PhotoItem
        let image: NSImage
        var cellFrame: CGRect
        var progress: CGFloat  // 1 = fullscreen, 0 = collapsed into the grid cell
        var interactive: Bool  // true = pinch-driven (the viewer is kept alive, invisible, behind this overlay)
    }

    @ViewBuilder private func zoomOverlay(_ z: ZoomTransition) -> some View {
        GeometryReader { geo in
            // This layer uses window coordinates to match the cell frames.
            // The content rectangle excludes the top bar and floating sidebar.
            let contentRect = CGRect(
                x: leadingObstructionInset, y: topBarInset,
                width: max(0, geo.size.width - leadingObstructionInset),
                height: max(0, geo.size.height - topBarInset))
            let full = fitRect(z.image, in: contentRect)
            let p = max(0, min(1, z.progress))
            let frame = Self.lerpRect(z.cellFrame, full, p)
            ZStack {
                ViewerVisualConstants.backgroundColor.opacity(p)  // Reveals the grid as the photo shrinks.
                    .padding(.leading, leadingObstructionInset)  // Covers only the detail area.
                Image(nsImage: z.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private static func lerpRect(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// Open the viewer for a photo identified only by uid (a Map pin tap). Looks it up in the currently loaded
    /// library list and opens directly (no cell-zoom - the grid cell is behind the map / may be off-screen).
    private func openPhotoByUID(_ uid: PhotoUID) {
        let items = timelineModel.wholeLibraryItemsForViewer
        guard let item = timelineModel.allLibraryItem(matching: uid) else { return }
        openPhoto(item, items)
    }

    private func showMapCluster(uids: [PhotoUID], coordinate: CLLocationCoordinate2D) {
        let orderedUIDs = timelineModel.allLibraryUIDs(matching: Set(uids))
        let pager = PhotoLocationClusterPager(uids: orderedUIDs)
        guard let firstPage = pager.page(at: 0), !firstPage.uids.isEmpty else { return }
        selectionMode = false
        selectedUIDs = []
        viewerModel = nil
        zoom = nil
        mapClusterPresentation = MapClusterPresentation(
            title: L10n.string("map.cluster_title"),
            coordinate: coordinate,
            pager: pager
        )
        mapClusterPageIndex = 0
        routeInitialScrollAnchor = nil
        loadMapClusterPage(firstPage.index)
    }

    private func loadMapClusterPage(_ index: Int) {
        guard let presentation = mapClusterPresentation,
            let page = presentation.pager.page(at: index)
        else { return }
        let items = timelineModel.allLibraryItems(matching: Set(page.uids))
        selectionMode = false
        selectedUIDs = []
        mapClusterPageIndex = index
        mapClusterRouteGeneration += 1
        let sectionID = "map-cluster-\(mapClusterRouteGeneration)"
        Task {
            await mapClusterModel.showTransientItems(items, sectionID: sectionID)
        }
    }

    private func closeMapCluster() {
        selectionMode = false
        selectedUIDs = []
        mapClusterPresentation = nil
    }

    private var activeGridProxy: GridProxy<PhotoUID> {
        mapClusterPresentation == nil ? gridProxy : mapClusterGridProxy
    }

    private func openPhoto(_ item: PhotoItem, _ items: [PhotoItem], proxy: GridProxy<PhotoUID>? = nil) {
        // Need the cell's on-screen frame and a thumbnail to fly; otherwise just open directly.
        let sourceProxy = proxy ?? activeGridProxy
        guard let cell = sourceProxy.windowFrameForItem?(item.uid), let img = feed.memoryImage(for: item.uid) else {
            viewerModel = makeViewer(item, items)
            return
        }
        zoom = ZoomTransition(item: item, image: img, cellFrame: cell, progress: 0, interactive: false)
        DispatchQueue.main.async {
            withAnimation(.spring(response: zoomOpenSpring.response, dampingFraction: zoomOpenSpring.damping)) {
                zoom?.progress = 1
            } completion: {
                viewerModel = makeViewer(item, items)
                zoom = nil
            }
        }
    }

    // MARK: Interactive pinch-to-dismiss

    /// Starts live dismissal toward the viewer's grid cell. Keeps the viewer mounted for gesture delivery.
    private func beginInteractiveDismiss() {
        // A new pinch supersedes an interactive dismissal. Preserve only a non-interactive open/close spring;
        // otherwise the gesture owns resolution.
        if let z = zoom, !z.interactive { return }
        guard let vm = viewerModel, let img = vm.image,
            let target = viewerReturnTarget(for: vm)
        else { return }
        zoom = ZoomTransition(item: target.item, image: img, cellFrame: target.cell, progress: 1, interactive: true)
    }

    /// Live pinch progress: 1 = fullscreen, 0 = collapsed into the cell.
    private func updateInteractiveDismiss(_ progress: CGFloat) {
        guard zoom?.interactive == true else { return }
        zoom?.progress = max(0, min(1, progress))
    }

    /// Fingers up: commit the close (fly the rest of the way into the cell) or spring back to fullscreen.
    private func endInteractiveDismiss(shouldClose: Bool) {
        guard zoom?.interactive == true else { return }
        zoom?.interactive = false  // Allows the viewer to hide after the gesture ends.
        DispatchQueue.main.async {
            withAnimation(.spring(response: zoomCloseSpring.response, dampingFraction: zoomCloseSpring.damping)) {
                zoom?.progress = shouldClose ? 0 : 1
            } completion: {
                if shouldClose { viewerModel = nil }
                zoom = nil
            }
        }
    }

    private func closePhoto() {
        guard let vm = viewerModel else { return }
        // Fly back to the photo's ACTUAL cell. If it scrolled off-screen (user navigated), close
        // instantly rather than centre-scrolling (which made it always shrink into the middle).
        guard let img = vm.image, let target = viewerReturnTarget(for: vm) else {
            viewerModel = nil
            return
        }
        zoom = ZoomTransition(item: target.item, image: img, cellFrame: target.cell, progress: 1, interactive: false)
        DispatchQueue.main.async {
            withAnimation(.spring(response: zoomCloseSpring.response, dampingFraction: zoomCloseSpring.damping)) {
                zoom?.progress = 0
            } completion: {
                viewerModel = nil
                zoom = nil
            }
        }
    }

    private func viewerReturnTarget(for vm: PhotoViewerModel) -> (item: PhotoItem, cell: CGRect)? {
        let preferredProxy = activeGridProxy
        for item in vm.gridReturnCandidates {
            if let cell = preferredProxy.windowFrameForItem?(item.uid) { return (item, cell) }
        }
        if mapClusterPresentation != nil {
            for item in vm.gridReturnCandidates {
                if let cell = gridProxy.windowFrameForItem?(item.uid) { return (item, cell) }
            }
        }
        return nil
    }

    private func makeViewer(_ item: PhotoItem, _ items: [PhotoItem]) -> PhotoViewerModel {
        let index = items.firstIndex(of: item) ?? 0
        let offline = OfflineLibraryManager.shared
        return PhotoViewerModel(
            items: items, index: index, feed: feed, media: backend,
            streamer: backend, metadataProvider: backend,
            albumMembershipProvider: facade.albums,
            placeNameResolver: NativePlaceNameResolver.shared,
            knownLocationUIDs: Set(offline.locationIndex.coordinates.map(\.uid)),
            burstProvider: backend,
            previewCache: offline.previewCache,
            originalsCache: offline.originalsCache,
            cacheOriginals: offline.offlineEnabled,
            originalsCapBytes: offline.originalsCapBytes)
    }

    /// Registers this window's thumbnail feed with the shared offline-cache manager, so the Settings
    /// scene can delete the cache and read status. The thumbnail crawl is mandatory grid infrastructure,
    /// independent of the Offline Photo Library toggle.
    private func attachOfflineManager() {
        let manager = OfflineLibraryManager.shared
        manager.attach(feed: feed, stats: backend)
        manager.liveAssetCount = timelineModel.wholeLibraryUIDs.count
        model.configureSmartSearch(
            feedCore: feed.feedCore,
            primaryItems: timelineModel.wholeLibraryItemsForViewer,
            primaryAuthority: timelineModel.wholeLibraryInventoryAuthority
        )
    }

    /// Aspect-fit rect of `image` centred in `size` - the photo's fullscreen frame.
    private func fitRect(_ image: NSImage, in size: CGSize) -> CGRect {
        let ia = image.size.width / max(image.size.height, 1)
        let ra = size.width / max(size.height, 1)
        var w = size.width
        var h = size.height
        if ia > ra { h = w / ia } else { w = h * ia }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Aspect-fit rect of `image` centred within an arbitrary `rect` (used to fit inside the media region
    /// below the top bar, not the whole window).
    private func fitRect(_ image: NSImage, in rect: CGRect) -> CGRect {
        let fitted = fitRect(image, in: rect.size)
        return fitted.offsetBy(dx: rect.minX, dy: rect.minY)
    }

    // MARK: - Chrome

    /// Shared cross-platform presentation decision. It becomes settled for a rendered non-empty cache without
    /// waiting for network validation, while cached empty remains covered until Proton confirms it.
    private var librarySettled: Bool {
        guard timelineModel.initialLibraryLoadState.hasSettled else { return false }
        guard !uploadRefreshBusy else { return false }
        if case .loading = timelineModel.state { return false }
        return true
    }

    /// Lifts the launch veil after visible thumbnails render.
    /// Empty and failed libraries lift it immediately because they have no thumbnails to render.
    private func evaluateVeilLift() {
        guard !model.libraryReady else {
            cancelVeilTasks()
            return
        }
        guard librarySettled else {
            cancelVeilTasks()
            return
        }
        if timelineModel.allItems.isEmpty {
            restoreInitialSidebarVisibilityIfNeeded()
            cancelVeilTasks()
            model.markLibraryReady()
            return
        }

        guard renderedLibraryRevision == timelineModel.gridSourceRevision else {
            veilSettleTask?.cancel()
            veilSettleTask = nil
            return
        }
        let revision = timelineModel.gridSourceRevision
        veilSettleTask?.cancel()
        veilSettleTask = Task { @MainActor in
            if !restoredInitialSidebarVisibility, !initiallyShowsSidebar {
                // Give the initially mounted `.all` column one committed titlebar frame before closing it.
                // Without this frame AppKit does not establish the toolbar's traffic-light exclusion region.
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }
            restoreInitialSidebarVisibilityIfNeeded()
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                librarySettled,
                renderedLibraryRevision == revision,
                timelineModel.gridSourceRevision == revision
            else { return }
            veilSettleTask = nil
            PhotoDiagnostics.shared.emit(
                "FirstContent",
                [
                    "event": "veilLift", "phase": "coldStart", "revision": "\(revision)",
                ])
            model.markLibraryReady()
        }
    }

    private func cancelVeilTasks() {
        veilSettleTask?.cancel()
        veilSettleTask = nil
    }

    private var title: String {
        if selection == .map, let mapClusterPresentation {
            return mapClusterPresentation.title
        }
        switch selection {
        case .all: return L10n.string("library.title")
        case .tag(let t): return t.title
        case .album(_, let name): return name
        case .trash: return String(localized: "sidebar.recently_deleted")
        case .map: return "Map"
        }
    }

    private enum NavigationChromeState: Equatable {
        case route(String)
        case mapCluster(String)
        case viewer
    }

    private var navigationChromeState: NavigationChromeState {
        if viewerModel != nil {
            return .viewer
        }
        if selection == .map, let mapClusterPresentation {
            return .mapCluster(mapClusterPresentation.title)
        }
        return .route(title)
    }

    private var navigationChromeAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0)
    }

    private var backgroundLibraryActivityActive: Bool {
        OfflineLibraryManager.shared.isLibraryActivityActive
    }

    private func retryAfterConnectivityRestored() {
        if selection.hasTimeline {
            Task { await timelineModel.retry() }
        }
        Task { await loadAlbums() }
        model.refreshLibrarySources()
        OfflineLibraryManager.shared.restartLocationCrawl(items: timelineModel.allItems, metadata: backend)
    }

    private var gridFillOrder: GridFillOrder {
        selection == .all && committedSearchText.isEmpty ? .newestBottomTrailing : .topLeading
    }

    private var showsTemporalBrowser: Bool {
        selection == .all
            && committedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && temporalMode != .allPhotos
    }

    private var temporalProjectionRequestID: String {
        "\(selection == .all ? "library" : "route")|\(temporalMode.rawValue)|\(timelineModel.contentRevision)"
    }

    private var temporalModeBinding: Binding<TimelineTemporalMode> {
        Binding {
            temporalMode
        } set: { mode in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                temporalMode = mode
                if mode != .months {
                    focusedTemporalYear = nil
                }
            }
        }
    }

    private func rebuildTemporalProjection() async {
        let mode = temporalMode
        guard selection == .all, mode != .allPhotos else { return }
        temporalProjection = .loading(mode: mode)
        let sections = currentTimelineSections
        do {
            let projection = try await TimelineTemporalProjection.build(
                mode: mode,
                sections: sections,
                calendar: Calendar.current
            )
            guard !Task.isCancelled, temporalMode == mode, selection == .all else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                temporalProjection = projection
            }
        } catch is CancellationError {
            return
        } catch {
            temporalProjection = TimelineTemporalProjection(
                mode: mode,
                sections: [],
                calendar: Calendar.current
            )
        }
    }

    private func selectTemporalYear(_ year: TimelineTemporalYearGroup) {
        focusedTemporalYear = Calendar.current.component(.year, from: year.dateInterval.start)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            temporalMode = .months
        }
    }

    private func loadAlbums() async {
        albumLoadGeneration &+= 1
        let loadGeneration = albumLoadGeneration
        async let owned: Void = albumActions.refresh()
        async let shared: Void = albumActions.refreshSharedAlbums()
        async let fetchedFavorites = try? backend.favoriteUIDs()
        let (_, _, newFavorites) = await (owned, shared, fetchedFavorites)
        guard !Task.isCancelled, loadGeneration == albumLoadGeneration else { return }
        if albumActions.loadErrorMessage == nil {
            albums = albumActions.albums
            uploadCoordinator.albums = albumActions.albums.map {
                UploadAlbumDestination(id: $0.id, title: $0.title)
            }
            albumCatalogFailed = false
        } else {
            // Preserve the last authoritative catalog during a transient/offline failure. Replacing
            // it with [] made real albums disappear and presented a false empty state until relaunch.
            albumCatalogFailed = true
        }
        if let newFavorites {
            favorites = newFavorites
        }
    }

    // MARK: - Upload

    private func performUploadUIAction(_ action: String, trigger: UploadUITrigger) {
        logUploadUI(action: action, trigger: trigger)
        switch action {
        case "uploadPhotos":
            presentUploadPhotos()
        case "uploadFolder":
            presentUploadFolder()
        case "showQueue":
            uploadCoordinator.isQueueVisible = true
        default:
            break
        }
    }

    private func presentUploadPhotos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie]
        panel.message = String(localized: "upload.choose_photos_message")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        uploadCoordinator.chooseDestination(files: panel.urls)
    }

    private func presentUploadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "upload.choose_folder_message")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        uploadCoordinator.chooseDestination(folder: folder)
    }

    private func scheduleUploadRefresh(_ event: UploadCompletedEvent) {
        uploadRefreshGeneration &+= 1
        let generation = uploadRefreshGeneration
        uploadRefreshTask?.cancel()
        uploadRefreshTask = Task { @MainActor in
            await runUploadRefresh(event, generation: generation)
            guard generation == uploadRefreshGeneration else { return }
            uploadRefreshTask = nil
        }
    }

    private func startLibraryChangeMonitor() async {
        // Coalesce with the timeline view's startup task, then seed monitoring with the token observed by the
        // shared cache validator. Starting earlier would consume a mutation during launch as a fresh baseline.
        await timelineModel.load()
        if timelineModel.initialLoadFailureReason == .scopeAccessLost {
            await model.recoverBackendAfterScopeAccessLoss()
            return
        }
        reconcileNewAssetThumbnails(timelineModel.takeInitialAuthoritativeAddedUIDs())
        guard let provider = backend as? any LibraryChangeTokenProvider else { return }
        await libraryChangeMonitor.start(
            provider: provider,
            initialToken: timelineModel.initialLibraryChangeToken,
            onTerminal: { [model] _ in
                await model.recoverBackendAfterScopeAccessLoss()
            },
            onChange: { await performRemoteLibraryRefresh() }
        )
    }

    @MainActor private func performRemoteLibraryRefresh() async -> LibraryChangeRefreshOutcome {
        guard uploadRefreshTask == nil, !uploadRefreshBusy else { return .retry }
        // The five-second token-driven comparison is routine synchronization, not user-facing progress. Keep the
        // gate for refresh serialization, but show the shared bottom banner only if the refreshed projection
        // actually schedules thumbnail or GPS work (observed by `backgroundLibraryActivityActive`).
        uploadRefreshBusy = true
        defer { uploadRefreshBusy = false }
        let result = await timelineModel.refreshLibrary()
        if result.failureReason == .scopeAccessLost { return .terminal }
        OfflineLibraryManager.shared.liveAssetCount = timelineModel.allItems.count
        await loadAlbums()
        model.refreshLibrarySources()
        reconcileNewAssetThumbnails(result.addedUIDs)
        return result.errorMessage == nil ? .refreshed : .retry
    }

    private func scheduleLibraryRefreshAfterBackupUpload() {
        uploadRefreshBusy = true
        uploadRefreshSuccess = false
        uploadRefreshMessage = String(localized: "library.refreshing")
        Task {
            await backupUploadRefreshCoordinator.request(
                refresh: { attempt in
                    await performBackupUploadRefreshAttempt(attempt: attempt)
                },
                observer: { state in
                    await applyBackupUploadRefresh(state)
                }
            )
        }
    }

    @MainActor private func performBackupUploadRefreshAttempt(attempt: Int) async -> TimelineRefreshFailureReason? {
        let result = await timelineModel.refreshLibrary()
        if await recoverBackendAfterScopeAccessLoss(ifNeeded: result) { return .cancelled }
        OfflineLibraryManager.shared.liveAssetCount = timelineModel.allItems.count
        reconcileNewAssetThumbnails(result.addedUIDs)
        logUploadRefresh(uploadedNode: "backup", attempt: attempt, result: result)
        return result.failureReason
    }

    @MainActor private func applyBackupUploadRefresh(_ state: TimelineUploadRefreshAttempt) {
        switch state.decision {
        case .succeeded:
            uploadRefreshBusy = false
            uploadRefreshSuccess = true
            uploadRefreshMessage = String(localized: "library.refreshed")
            clearUploadRefreshMessage(after: .seconds(2))
        case .retry:
            uploadRefreshMessage = String(localized: "upload.waiting_for_refresh")
        case .notYetVisible:
            uploadRefreshBusy = false
            uploadRefreshMessage = String(localized: "upload.not_yet_indexed")
        case .failed:
            uploadRefreshBusy = false
            uploadRefreshMessage = String(localized: "library.refresh_failed")
            clearUploadRefreshMessage(after: .seconds(2))
        case .cancelled:
            uploadRefreshBusy = false
            uploadRefreshMessage = nil
        }
    }

    @MainActor private func runUploadRefresh(_ event: UploadCompletedEvent, generation: UInt64) async {
        uploadRefreshBusy = true
        uploadRefreshSuccess = false
        uploadRefreshMessage = String(localized: "upload.refreshing_after_upload")
        let schedule = TimelineRefreshRetrySchedule.uploadDefault.delays
        for (attempt, delay) in schedule.enumerated() {
            guard generation == uploadRefreshGeneration, !Task.isCancelled else { return }
            if delay > .zero {
                uploadRefreshMessage = String(localized: "upload.waiting_for_refresh")
                try? await Task.sleep(for: delay)
            }
            let result = await timelineModel.refreshAfterUpload(uploadedUID: event.uploadedUID)
            guard generation == uploadRefreshGeneration, !Task.isCancelled else { return }
            if await recoverBackendAfterScopeAccessLoss(ifNeeded: result) { return }
            OfflineLibraryManager.shared.liveAssetCount = timelineModel.allItems.count
            reconcileNewAssetThumbnails(result.addedUIDs)
            if event.destination.usesAlbum {
                await loadAlbums()
            }
            logUploadRefresh(upload: event, attempt: attempt, result: result)
            if let found = result.foundItem {
                uploadRefreshBusy = false
                uploadRefreshSuccess = true
                uploadRefreshMessage = String(localized: "upload.uploaded")
                gridProxy.scrollToItem?(found.uid)
                clearUploadRefreshMessage(after: .seconds(2))
                return
            }
        }
        uploadRefreshBusy = false
        uploadRefreshSuccess = false
        uploadRefreshMessage = String(localized: "upload.not_yet_indexed")
    }

    private func refreshLibraryManually() {
        Task { await performManualLibraryRefresh() }
    }

    @MainActor private func performManualLibraryRefresh() async {
        guard !uploadRefreshBusy else { return }
        uploadRefreshBusy = true
        uploadRefreshSuccess = false
        uploadRefreshMessage = String(localized: "library.refreshing")
        let result = await timelineModel.refreshLibrary()
        if await recoverBackendAfterScopeAccessLoss(ifNeeded: result) { return }
        OfflineLibraryManager.shared.liveAssetCount = timelineModel.allItems.count
        await loadAlbums()
        reconcileNewAssetThumbnails(result.addedUIDs)
        logUploadRefresh(uploadedNode: "-", attempt: 0, result: result)
        uploadRefreshBusy = false
        uploadRefreshSuccess = result.errorMessage == nil
        uploadRefreshMessage =
            result.errorMessage == nil
            ? String(localized: "library.refreshed") : String(localized: "library.refresh_failed")
        clearUploadRefreshMessage(after: .seconds(2))
    }

    @MainActor private func recoverBackendAfterScopeAccessLoss(
        ifNeeded result: TimelineRefreshResult
    ) async -> Bool {
        guard result.failureReason == .scopeAccessLost else { return false }
        uploadRefreshBusy = false
        uploadRefreshSuccess = false
        uploadRefreshMessage = nil
        await model.recoverBackendAfterScopeAccessLoss()
        return true
    }

    private func clearUploadRefreshMessage(after delay: Duration) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !uploadRefreshBusy else { return }
            uploadRefreshMessage = nil
        }
    }

    @MainActor private func reconcileNewAssetThumbnails(_ addedUIDs: [PhotoUID]) {
        OfflineLibraryManager.shared.reconcileNewAssetThumbnails(
            currentUIDs: timelineModel.wholeLibraryUIDs,
            addedUIDs: addedUIDs
        )
    }

    private func logUploadUI(action: String, trigger: UploadUITrigger) {
        let line = "[UploadUI] action=\(action) trigger=\(trigger.rawValue)"
        DebugLog.log(line)
    }

    private func logUploadRefresh(upload: UploadCompletedEvent, attempt: Int, result: TimelineRefreshResult) {
        logUploadRefresh(uploadedNode: upload.uploadedUID.nodeID, attempt: attempt, result: result)
    }

    private func logUploadRefresh(uploadedNode: String, attempt: Int, result: TimelineRefreshResult) {
        let line = """
            [UploadRefresh] uploadedNode=\(uploadedNode) attempt=\(attempt) found=\(result.found) \
            timelineCountBefore=\(result.timelineCountBefore) timelineCountAfter=\(result.timelineCountAfter) \
            filter=\(result.filterDescription) elapsedMs=\(Int(result.elapsedMs)) error=\(result.errorMessage ?? "-")
            """
        DebugLog.log(line)
    }

    /// Honest Map empty state, mirroring the iOS states and the standard macOS library empty surface.
    @ViewBuilder private var mapEmptyState: some View {
        let index = OfflineLibraryManager.shared.locationIndex
        Group {
            if !networkMonitor.isOnline {
                OfflineContentUnavailableView()
            } else {
                switch index.scanProgress.phase {
                case .scanning:
                    ContentUnavailableView {
                        Label(L10n.string("map.scanning_title"), systemImage: "location.magnifyingglass")
                    } description: {
                        Text(
                            L10n.string(
                                "map.scanning_message \(index.scanProgress.scanned) \(index.scanProgress.total)"))
                    }
                case .failed:
                    ContentUnavailableView {
                        Label(L10n.string("map.scan_failed_title"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(L10n.string("map.scan_failed_message"))
                    }
                case .completed:
                    ContentUnavailableView {
                        Label(L10n.string("map.empty_title"), systemImage: "mappin.slash")
                    } description: {
                        Text(L10n.string("map.no_places_found_message"))
                    }
                case .idle:
                    ContentUnavailableView {
                        Label(L10n.string("map.empty_title"), systemImage: "mappin.slash")
                    } description: {
                        Text(L10n.string("map.empty_message"))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
    }

    // MARK: - Favorites / trash

    private func toggleFavorite(_ uid: PhotoUID) {
        let selection = Set([uid])
        guard let target = FavoriteMutationPolicy.target(for: selection, current: favorites) else { return }
        let requested = FavoriteMutationPolicy.requestedUIDs(
            selection: selection,
            current: favorites,
            target: target
        )
        favorites = FavoriteMutationPolicy.optimisticState(
            current: favorites,
            requested: requested,
            target: target
        )
        Task {
            do {
                try await backend.setFavorites(Array(requested), target)
            } catch let partial as FavoriteMutationError {
                rollbackFavoriteMutation(partial.failed, target: target)
            } catch {
                rollbackFavoriteMutation(requested, target: target)
            }
        }
    }

    /// Indicates whether every selected photo is a favorite.
    private var selectedAllFavorited: Bool {
        !selectedUIDs.isEmpty && selectedUIDs.allSatisfy { favorites.contains($0) }
    }

    /// Toggles the favorite state for the selection and rolls back only failed items.
    private func favoriteSelected() {
        guard let target = FavoriteMutationPolicy.target(for: selectedUIDs, current: favorites) else { return }
        let uids = FavoriteMutationPolicy.requestedUIDs(
            selection: selectedUIDs,
            current: favorites,
            target: target
        )
        guard !uids.isEmpty else { return }
        favorites = FavoriteMutationPolicy.optimisticState(
            current: favorites,
            requested: uids,
            target: target
        )
        Task {
            do {
                try await backend.setFavorites(Array(uids), target)
            } catch let partial as FavoriteMutationError {
                rollbackFavoriteMutation(partial.failed, target: target)
            } catch {
                rollbackFavoriteMutation(Set(uids), target: target)
            }
        }
    }

    private func rollbackFavoriteMutation(_ failed: Set<PhotoUID>, target: Bool) {
        favorites = FavoriteMutationPolicy.rollbackState(current: favorites, failed: failed, target: target)
    }

    /// Sets the single selected photo as the current album's cover (direct REST), then refreshes the album list
    /// so the sidebar cover updates. Keeps the selection (non-destructive).
    private func setSelectedAsAlbumCover(albumID: String) {
        guard selectedUIDs.count == 1, let uid = selectedUIDs.first, !isSettingAlbumCover else { return }
        isSettingAlbumCover = true
        Task {
            defer { isSettingAlbumCover = false }
            do {
                try await facade.albums.setAlbumCover(albumID: albumID, photoUID: uid)
                await loadAlbums()
            } catch {
                albumCoverFailureMessage = String(
                    localized: "albums.cover_failed_message \(error.localizedDescription)")
            }
        }
    }

    private func deleteCurrentAlbum() {
        guard case .album(let albumID, _) = selection, !isDeletingAlbum else { return }
        isDeletingAlbum = true
        Task {
            defer { isDeletingAlbum = false }
            do {
                try await facade.albums.deleteAlbum(albumID: albumID)
                selectionMode = false
                selectedUIDs.removeAll()
                selection = .all
                await loadAlbums()
            } catch {
                albumDeleteFailureMessage = L10n.string("albums.delete_failed_message")
            }
        }
    }

    private func requestSelectedRemovalOrTrash() {
        if case .album = selection {
            confirmAlbumPhotoAction = true
        } else {
            trashSelected()
        }
    }

    private func removeSelectedFromCurrentAlbum() {
        guard case .album(let albumID, _) = selection,
            !selectedUIDs.isEmpty,
            !isTrashMutating
        else { return }
        let uids = Array(selectedUIDs)
        isTrashMutating = true
        Task {
            defer { isTrashMutating = false }
            do {
                try await facade.albums.removePhotos(uids, from: albumID)
                await timelineModel.select(selection)
                await loadAlbums()
                selectionMode = false
                selectedUIDs.removeAll()
            } catch {
                albumMembershipFailureMessage = L10n.string("albums.remove_photos_failed_message")
            }
        }
    }

    private func trashPhotos(_ items: [PhotoItem], closeViewer: Bool) {
        let uids = items.map(\.uid)
        guard !uids.isEmpty, !isTrashMutating else { return }
        isTrashMutating = true
        Task {
            defer { isTrashMutating = false }
            do {
                try await backend.trash(uids)
                await timelineModel.commitTrash(items)
                if mapClusterPresentation != nil { await mapClusterModel.commitTrash(items) }
                await OfflineLibraryManager.shared.reconcileLocations(
                    items: timelineModel.wholeLibraryItemsForViewer,
                    metadata: backend,
                    recrawlRestoredItems: false
                )
                favorites = (try? await backend.favoriteUIDs()) ?? favorites.subtracting(uids)
                selectionMode = false
                selectedUIDs = []
                if closeViewer { closePhoto() }
            } catch {
                DebugLog.log("trash: FAILED n=\(uids.count) - \(error)")
                trashActionFailureMessage = String(localized: "alert.trash_failed_message")
            }
        }
    }

    private func restorePhotos(_ items: [PhotoItem], closeViewer: Bool = false) {
        let uids = items.map(\.uid)
        guard !uids.isEmpty, !isTrashMutating else { return }
        isTrashMutating = true
        Task {
            defer { isTrashMutating = false }
            do {
                try await backend.restore(uids)
                await timelineModel.commitRestore(items)
                await OfflineLibraryManager.shared.reconcileLocations(
                    items: timelineModel.wholeLibraryItemsForViewer,
                    metadata: backend,
                    recrawlRestoredItems: true
                )
                favorites = (try? await backend.favoriteUIDs()) ?? favorites
                selectionMode = false
                selectedUIDs = []
                if closeViewer { closePhoto() }
            } catch {
                DebugLog.log("restore: FAILED n=\(uids.count) - \(error)")
                trashActionFailureMessage = String(localized: "alert.restore_failed_message")
            }
        }
    }

    private func emptyTrash() {
        let uids = Set(timelineModel.allItems.map(\.uid))
        guard selection == .trash, !uids.isEmpty, !isEmptyingTrash else { return }
        isEmptyingTrash = true
        Task {
            defer { isEmptyingTrash = false }
            do {
                try await backend.emptyTrash()
                timelineModel.commitEmptyTrash(uids)
                selectedUIDs = []
                selectionMode = false
            } catch {
                DebugLog.log("empty-trash: FAILED n=\(uids.count) - \(error)")
                await timelineModel.retry()
                trashActionFailureMessage = L10n.string("trash.empty_failed_message")
            }
        }
    }

    private var selectedItems: [PhotoItem] {
        if mapClusterPresentation != nil {
            return mapClusterModel.allItems.filter { selectedUIDs.contains($0.uid) }
        }
        // The retained Core snapshot answers the whole-library selection without scanning every item on each
        // action. Filtered routes keep their active-route ordering and membership because their items can include
        // trash or album-only identities that are not present in the whole-library snapshot.
        if timelineModel.filter == .all {
            return timelineModel.allLibraryItems(matching: selectedUIDs)
        }
        return timelineModel.allItems.filter { selectedUIDs.contains($0.uid) }
    }

    private func scheduleSearchCommit(_ value: String) {
        searchDebounceTask?.cancel()
        if semanticQuery == nil, let smartSearch = model.smartSearch {
            semanticQuery = MLSmartSearchQueryCoordinator(
                lifecycle: smartSearch.lifecycleActor,
                initialScope: searchScope
            )
        }
        semanticQuery?.update(query: value)
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            committedSearchText = ""
            // Clearing the search returns the full timeline to its newest item.
            routeInitialScrollAnchor = nil
            routeScrollGeneration += 1
            searchDebounceTask = nil
            return
        }
        if temporalMode != .allPhotos {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                temporalMode = .allPhotos
                focusedTemporalYear = nil
            }
        }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            routeInitialScrollAnchor = nil
            routeScrollGeneration += 1
            committedSearchText = value
            searchDebounceTask = nil
        }
    }

    private var currentTimelineSections: [TimelineSection] {
        guard case .loaded(let sections) = timelineModel.state else { return [] }
        return sections
    }

    private func recordSearchHistory(_ rawQuery: String) {
        var next = searchHistory
        next.record(rawQuery)
        guard next != searchHistory else { return }
        searchHistory = next
    }

    private func clearSearchHistory() {
        searchHistory.clear()
    }

    private var normalizedCommittedSearchText: String {
        committedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isCommittedSemanticSearchPending: Bool {
        semanticQuery?.requestedQuery == normalizedCommittedSearchText
            && semanticQuery?.isSearching == true
    }

    private var committedSemanticMatches: Set<PhotoUID>? {
        guard semanticQuery?.resolvedQuery == normalizedCommittedSearchText else { return nil }
        return semanticQuery?.rankedUIDs.map(Set.init)
    }

    private func trashSelected() {
        let items = selectedItems
        requestTrash(items, closeViewer: false)
    }

    private func restoreSelected() {
        let items = selectedItems
        restorePhotos(items)
    }

    private func requestTrash(_ items: [PhotoItem], closeViewer: Bool) {
        guard !items.isEmpty else { return }
        pendingTrashItems = items
        closeViewerAfterTrash = closeViewer
        confirmTrash = true
    }

    private var trashConfirmationTitle: String {
        pendingTrashItems.count == 1
            ? String(localized: "alert.trash_confirmation_title_one")
            : String(localized: "alert.trash_confirmation_title_other \(pendingTrashItems.count)")
    }

    private var trashConfirmationMessage: String {
        pendingTrashItems.count == 1
            ? String(localized: "alert.trash_confirmation_message_one")
            : String(localized: "alert.trash_confirmation_message_other")
    }

    /// Applies detail controls at split-view scope. NavigationSplitView owns its default sidebar control so macOS
    /// places it in the sidebar's title-bar region, matching Apple Photos.
    private func synchronizedToolbar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .toolbar { toolbarContent }
            // Keep one logical native toolbar group while its contents change. macOS can then morph the
            // system-supplied Liquid Glass shape instead of tearing down one capsule and mounting another.
            .animation(navigationChromeAnimation, value: navigationChromeState)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .contentTransition(.interpolate)
                .accessibilityAddTraits(.isHeader)
        }
        .hidden(viewerModel != nil)
        .sharedBackgroundVisibility(.visible)

        ToolbarItem(placement: .navigation) {
            Button {
                if viewerModel != nil {
                    closePhoto()
                } else {
                    closeMapCluster()
                }
            } label: {
                Label("toolbar.back", systemImage: "chevron.left")
            }
            .help("toolbar.back_to_library")
        }
        .hidden(viewerModel == nil && !(selection == .map && mapClusterPresentation != nil))
        .sharedBackgroundVisibility(.visible)

        if let viewerModel {
            // Apple-Photos centered two-line metadata in a pill: location/POI (or date) over the
            // secondary line, both inside a capsule padded comfortably larger than the text.
            ToolbarItem(placement: .principal) {
                let t = viewerTitle(viewerModel)
                VStack(spacing: 1) {
                    Text(t.line1)
                        .font(.system(size: 13, weight: .semibold))
                        .opacity(t.reservesLocationLine ? 0 : 1)
                        .lineLimit(1)
                    Text(t.line2)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                // The system toolbar supplies the single glass background for the principal item.
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation(
                        .easeInOut(
                            duration: ViewerChromePresentationStyle.standard.inspectorDuration
                        )
                    ) {
                        viewerModel.toggleInfo()
                    }
                } label: {
                    Label("toolbar.info", systemImage: viewerModel.showInfo ? "info.circle.fill" : "info.circle")
                        .labelStyle(.iconOnly)
                }
                .help("toolbar.info")
                .accessibilityLabel("toolbar.info")

                if isExporting {
                    exportProgressIndicator  // the download icon is replaced by the native progress while exporting
                    exportCancelButton
                } else {
                    let downloadTitle =
                        viewerModel.hasBurstFilmstrip ? "toolbar.download_burst_zip" : "toolbar.download_original"
                    Button {
                        downloadViewerSelection(viewerModel)
                    } label: {
                        Label(LocalizedStringKey(downloadTitle), systemImage: "square.and.arrow.down")
                            .labelStyle(.iconOnly)
                    }
                    .help(LocalizedStringKey(downloadTitle))
                    .accessibilityLabel(LocalizedStringKey(downloadTitle))
                    .disabled(!viewerModel.canDownloadCurrentSelection)
                }

                Button {
                    toggleFavorite(viewerModel.current.uid)
                } label: {
                    Label(
                        favorites.contains(viewerModel.current.uid) ? "toolbar.remove_favorite" : "toolbar.favorite",
                        systemImage: favorites.contains(viewerModel.current.uid) ? "heart.fill" : "heart"
                    )
                    .labelStyle(.iconOnly)
                }
                .help(favorites.contains(viewerModel.current.uid) ? "toolbar.remove_favorite" : "toolbar.favorite")
                .accessibilityLabel(
                    favorites.contains(viewerModel.current.uid) ? "toolbar.remove_favorite" : "toolbar.favorite")

                Menu {
                    if viewerMutationAction == .restore {
                        Button {
                            performViewerMutation(viewerModel.current)
                        } label: {
                            Label("toolbar.restore_from_trash", systemImage: "arrow.uturn.backward")
                        }
                    } else {
                        Button(role: .destructive) {
                            performViewerMutation(viewerModel.current)
                        } label: {
                            Label("toolbar.move_to_trash", systemImage: "trash")
                        }
                    }
                } label: {
                    Label(L10n.string("albums.more_actions"), systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .help(L10n.string("albums.more_actions"))
                .accessibilityLabel(L10n.string("albums.more_actions"))
                .disabled(isTrashMutating)
            }
        } else {
            // Click / ⌘-click / ⇧-click / drag-marquee select directly, while an album's native menu can
            // also make selection mode explicit. The toolbar is stable - the download (or restore) + trash actions
            // are always present and just enable when something is selected. The scene's hidden title-bar style
            // requires the route title to occupy the native navigation placement explicitly; a non-control Text
            // remains plain while reserving the expected leading toolbar width. The activity/offline indicator is
            // an unframed content overlay, not a toolbar item.
            // Apple toolbars have semantic regions: library commands use primaryAction, common view controls
            // occupy the principal center, and selection actions use secondaryAction alongside the system-owned
            // search field. Fixed spacers only separate independent primary commands.
            if case .album = selection {
                ToolbarItem(placement: .primaryAction) { albumActionsToolbarMenu }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) { createAlbumToolbarMenu }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { uploadToolbarMenu }
            librarySelectionAndViewToolbarContent
        }

        if viewerModel == nil,
            let mapClusterPresentation,
            mapClusterPresentation.pager.pageCount > 1
        {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    loadMapClusterPage(mapClusterPageIndex - 1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(mapClusterPageIndex == 0)
                Text("\(mapClusterPageIndex + 1)/\(mapClusterPresentation.pager.pageCount)")
                    .monospacedDigit()
                Button {
                    loadMapClusterPage(mapClusterPageIndex + 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(mapClusterPageIndex + 1 >= mapClusterPresentation.pager.pageCount)
            }
        }
    }

    @ToolbarContentBuilder private var librarySelectionAndViewToolbarContent: some ToolbarContent {
        if selection != .trash {
            ToolbarItemGroup(placement: .secondaryAction) {
                downloadActionItem
                Button {
                    showAlbumDestination = true
                } label: {
                    Label(L10n.string("albums.add_selection_title"), systemImage: "rectangle.stack.badge.plus")
                        .labelStyle(.iconOnly)
                }
                .disabled(selectedUIDs.isEmpty || !albumActions.canAddPhotos)
                .help(L10n.string("albums.add_selection_title"))
                .accessibilityLabel(L10n.string("albums.add_selection_title"))
                .popover(isPresented: $showAlbumDestination, arrowEdge: .top) {
                    AlbumDestinationPicker(
                        coordinator: albumActions,
                        photoUIDs: Array(selectedUIDs),
                        onAlbumsChanged: { Task { await loadAlbums() } },
                        onCompleted: { _ in
                            showAlbumDestination = false
                            selectionMode = false
                            selectedUIDs.removeAll()
                        }
                    )
                }
                Button {
                    requestSelectedRemovalOrTrash()
                } label: {
                    Label("toolbar.move_selected_to_trash", systemImage: "trash").labelStyle(.iconOnly)
                }
                .disabled(selectedUIDs.isEmpty || isTrashMutating)
                .help("toolbar.move_to_trash")
                .accessibilityLabel("toolbar.move_selected_to_trash")
                Button {
                    favoriteSelected()
                } label: {
                    Label(
                        selectedAllFavorited ? "toolbar.remove_favorite" : "toolbar.favorite_selected",
                        systemImage: selectedAllFavorited ? "heart.fill" : "heart"
                    )
                    .labelStyle(.iconOnly)
                }
                .disabled(selectedUIDs.isEmpty)
                .help(selectedAllFavorited ? "toolbar.remove_favorite" : "toolbar.favorite_selected")
                .accessibilityLabel(selectedAllFavorited ? "toolbar.remove_favorite" : "toolbar.favorite_selected")
                if case .album(let albumID, _) = selection {
                    Button {
                        setSelectedAsAlbumCover(albumID: albumID)
                    } label: {
                        Label("toolbar.set_album_cover", systemImage: "rectangle.badge.checkmark").labelStyle(.iconOnly)
                    }
                    .disabled(selectedUIDs.count != 1 || isSettingAlbumCover)
                    .help("toolbar.set_album_cover")
                    .accessibilityLabel("toolbar.set_album_cover")
                }
            }
        } else {
            ToolbarItemGroup(placement: .secondaryAction) {
                downloadActionItem
                Button {
                    confirmEmptyTrash = true
                } label: {
                    Label(L10n.string("trash.empty_button"), systemImage: "trash.slash").labelStyle(.iconOnly)
                }
                .disabled(timelineModel.allItems.isEmpty || isEmptyingTrash || isTrashMutating)
                .help(L10n.string("trash.empty_button"))
                .accessibilityLabel(L10n.string("trash.empty_button"))
            }
        }
        ToolbarItemGroup(placement: .principal) {
            Picker("", selection: temporalModeBinding) {
                Text(L10n.string("library.view_years")).tag(TimelineTemporalMode.years)
                Text(L10n.string("library.view_months")).tag(TimelineTemporalMode.months)
                Text(L10n.string("library.view_all_photos")).tag(TimelineTemporalMode.allPhotos)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)
            .opacity(selection == .all ? 1 : 0)
            .allowsHitTesting(selection == .all)
            .accessibilityHidden(selection != .all)

            ControlGroup {
                Button {
                    activeGridProxy.zoomOut?()
                } label: {
                    Label("toolbar.smaller_thumbnails", systemImage: "minus").labelStyle(.iconOnly)
                }
                .help("toolbar.smaller_thumbnails")
                .disabled(level >= 5 || temporalMode != .allPhotos)
                .accessibilityLabel("toolbar.smaller_thumbnails")
                Button {
                    activeGridProxy.zoomIn?()
                } label: {
                    Label("toolbar.larger_thumbnails", systemImage: "plus").labelStyle(.iconOnly)
                }
                .help("toolbar.larger_thumbnails")
                .disabled(level <= 0 || temporalMode != .allPhotos)
                .accessibilityLabel("toolbar.larger_thumbnails")
            }
            aspectSquareToggleButton
        }
    }

    /// Toggles thumbnail content fitting without changing grid geometry.
    /// Dense overview levels always use square cropping.
    private var aspectSquareToggleButton: some View {
        Button {
            gridContentMode = AspectSquareToggleModel.toggled(gridContentMode)
            activeGridProxy.setContentMode?(gridContentMode)
        } label: {
            Image(nsImage: AspectSquareToggleModel.image(for: gridContentMode))
        }
        .help(AspectSquareToggleModel.accessibilityLabel(for: gridContentMode))
        .accessibilityLabel(AspectSquareToggleModel.accessibilityLabel(for: gridContentMode))
        .disabled(level >= 4 || temporalMode != .allPhotos)  // overview and curated modes are square-only
    }

    private var viewerMutationAction: ViewerMutationAction {
        ViewerMutationPolicy.action(for: ViewerCollectionContext(filter: selection))
    }

    private func performViewerMutation(_ item: PhotoItem) {
        switch viewerMutationAction {
        case .moveToTrash:
            requestTrash([item], closeViewer: true)
        case .restore:
            restorePhotos([item], closeViewer: true)
        }
    }

    /// Center-title metadata for the viewer top bar. `placeName` is the reverse-geocoded POI/location
    /// headline (nil until resolved or when the photo has no GPS); the filename fallback is best-effort
    /// (only populated while the Info panel is open).
    private func viewerTitle(_ vm: PhotoViewerModel) -> ViewerTitle {
        ViewerTitleFormatter.make(
            captureDate: vm.current.captureTime,
            index: vm.index,
            total: vm.items.count,
            locationName: vm.placeName,
            locationIsResolving: vm.isPlaceNameResolving,
            filename: vm.metadata?.filename
        )
    }

    // MARK: - Sidebar

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            sidebarOpen.toggle()
            columnVisibility = sidebarOpen ? .all : .detailOnly  // drive the native split view
        }
        SidebarPersistence.saveVisible(sidebarOpen)
    }

    private func restoreInitialSidebarVisibilityIfNeeded() {
        guard !restoredInitialSidebarVisibility else { return }
        restoredInitialSidebarVisibility = true
        guard !initiallyShowsSidebar else { return }

        // This is called only after the first content frame or a settled empty/error state. By then AppKit has
        // committed the `.all` mount. Drive the same native transition as a real sidebar toggle so AppKit also
        // establishes its titlebar navigation region; the launch cover and its 250 ms settle barrier hide it.
        withAnimation(.easeInOut(duration: 0.22)) {
            sidebarOpen = false
            columnVisibility = .detailOnly
        }
    }

    // MARK: - Download / export

    private struct ExportRequest {
        let items: [PhotoItem]
        let zipSuggestedName: String?
    }

    private func downloadSelected() {
        let items = selectedItems
        guard !items.isEmpty, !isExporting else { return }
        Task { @MainActor in
            let request = await makeExportRequest(
                for: items, preferredSeriesNameSource: items.count == 1 ? items[0] : nil)
            startOrConfirmExport(request)
        }
    }

    private func downloadViewerSelection(_ viewerModel: PhotoViewerModel) {
        let items = viewerModel.exportItemsForDownload
        guard !items.isEmpty, !isExporting else { return }
        Task { @MainActor in
            let request = await makeExportRequest(for: items, preferredSeriesNameSource: viewerModel.baseCurrent)
            startOrConfirmExport(request)
        }
    }

    private func startOrConfirmExport(_ request: ExportRequest) {
        guard !request.items.isEmpty, !isExporting else { return }
        if request.items.count > largeExportThreshold {
            pendingExportItems = request.items
            pendingExportZipName = request.zipSuggestedName
            confirmLargeExport = true  // confirm large multi-downloads before zipping
        } else {
            startExport(request.items, zipSuggestedName: request.zipSuggestedName)
        }
    }

    /// Expands a selected Proton burst/series title photo into all known members before export. This keeps the
    /// grid toolbar and viewer toolbar on the same E2EE-safe export path; only the item list and suggested ZIP
    /// filename are prepared here.
    @MainActor private func makeExportRequest(
        for sourceItems: [PhotoItem],
        preferredSeriesNameSource: PhotoItem?
    ) async -> ExportRequest {
        var expanded: [PhotoItem] = []
        var seen = Set<PhotoUID>()
        var expandedSingleSeries = false

        func appendUnique(_ item: PhotoItem) {
            guard seen.insert(item.uid).inserted else { return }
            expanded.append(item)
        }

        let memberIDSet = Set(
            (preferredSeriesNameSource?.burstMemberIDs ?? []).map {
                PhotoUID(volumeID: preferredSeriesNameSource?.uid.volumeID ?? "", nodeID: $0)
            })
        let sourceUIDSet = Set(sourceItems.map(\.uid))
        let alreadyExpandedPreferredSeries =
            sourceItems.count > 1
            && preferredSeriesNameSource?.isBurstCandidate == true
            && !memberIDSet.isEmpty
            && sourceUIDSet.isSubset(of: memberIDSet)

        if alreadyExpandedPreferredSeries {
            sourceItems.forEach(appendUnique)
            expandedSingleSeries = true
        } else {
            for item in sourceItems {
                if item.isBurstCandidate,
                    let group = try? await backend.burstGroup(containing: item.uid),
                    group.count > 1
                {
                    group.forEach(appendUnique)
                    expandedSingleSeries = true
                } else {
                    appendUnique(item)
                }
            }
        }

        let zipName: String?
        if expandedSingleSeries, expanded.count > 1, let source = preferredSeriesNameSource ?? sourceItems.first {
            zipName = await suggestedSeriesZipName(for: source)
        } else {
            zipName = nil
        }
        return ExportRequest(items: expanded, zipSuggestedName: zipName)
    }

    @MainActor private func suggestedSeriesZipName(for item: PhotoItem) async -> String {
        let meta = try? await backend.metadata(for: item.uid)
        let fallback = Self.defaultName(item, ext: Self.defaultExtension(item, metadata: meta))
        let filename = meta?.filename?.isEmpty == false ? meta?.filename : fallback
        let stem = URL(fileURLWithPath: filename ?? fallback).deletingPathExtension().lastPathComponent
        let safeStem = stem.isEmpty ? "EncryptedMemories" : stem
        return "\(safeStem)-\(String(localized: "export.series_zip_suffix")).zip"
    }

    /// Single entry point for launching an export, so the toolbar ring's menu has one task to cancel.
    private func startExport(_ items: [PhotoItem], zipSuggestedName: String? = nil) {
        exportTask?.cancel()
        exportTask = Task { await performExport(items, zipSuggestedName: zipSuggestedName) }
    }

    /// Cancels the running download (from the toolbar ring's menu). `performExport` discards any partial ZIP.
    private func cancelExport() { exportTask?.cancel() }

    /// Coordinates destination selection and UI state; transfer and file work remain off the main actor.
    @MainActor private func performExport(_ items: [PhotoItem], zipSuggestedName: String?) async {
        let backend = self.backend
        // Captures self only to push 0…1 onto the @State ring; the closure itself runs on the main actor.
        let onProgress: @Sendable (Double) -> Void = { p in Task { @MainActor in self.exportFraction = p } }

        // Show progress only after the user has selected a destination.
        let single = items.count == 1
        let dest: URL
        if single {
            let item = items[0]
            let meta = try? await backend.metadata(for: item.uid)
            let name = meta?.filename ?? Self.defaultName(item, ext: Self.defaultExtension(item, metadata: meta))
            guard let chosen = chooseSingleDestination(suggestedName: name) else { return }
            dest = chosen
        } else {
            // Stream multi-item exports into one archive, staging one SDK download at a time.
            guard let chosen = chooseZipDestination(suggestedName: zipSuggestedName) else { return }
            dest = chosen
        }

        // Keep the Powerbox grant active for the complete asynchronous export.
        let hasScopedAccess = dest.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                dest.stopAccessingSecurityScopedResource()
            }
        }

        // The transfer starts after destination selection, so progress can now become visible.
        exportFraction = 0
        withAnimation(.smooth(duration: 0.35)) { isExporting = true }
        defer {
            withAnimation(.smooth(duration: 0.3)) { isExporting = false }
            exportTask = nil
        }

        do {
            if single {
                try await Self.writeSingleExport(item: items[0], dest: dest, backend: backend, onProgress: onProgress)
            } else {
                try await Self.writeZipExport(items: items, dest: dest, backend: backend, onProgress: onProgress)
            }
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch is CancellationError {
            // User cancelled from the ring popover; the worker's `defer` already discarded any partial output.
        } catch ExportError.lowDisk {
            exportFailureTitle = String(localized: "export.low_disk_title")
            exportFailureMessage = String(localized: "export.low_disk_message")
        } catch {
            DebugLog.log("export failed: \(error)")
            exportFailureTitle = String(localized: "export.failed_title")
            exportFailureMessage = String(localized: "export.failed_message \(error.localizedDescription)")
        }
    }

    /// Off-main single-file export: stage on the destination volume, then atomically install the completed file.
    nonisolated private static func writeSingleExport(
        item: PhotoItem, dest: URL, backend: any PhotosBackend,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let stagingDirectory = try exportReplacementDirectory(for: dest)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagedFile = stagingDirectory.appendingPathComponent(dest.lastPathComponent, isDirectory: false)
        try await backend.writeOriginal(for: item.uid, to: stagedFile, onProgress: onProgress)
        try installCompletedExport(stagedFile, at: dest)
    }

    /// Streams an archive off the main actor and removes partial output on every unsuccessful exit.
    nonisolated private static func writeZipExport(
        items: [PhotoItem], dest: URL, backend: any PhotosBackend,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let total = Double(items.count)
        let stagingDirectory = try exportReplacementDirectory(for: dest)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagedArchive = stagingDirectory.appendingPathComponent(dest.lastPathComponent, isDirectory: false)
        let safetyMargin: Int64 = 256 * 1024 * 1024  // headroom (incl. the central directory)
        let writer = try ZipStreamWriter(url: stagedArchive)
        var success = false
        defer { if !success { writer.abort() } }
        var used = Set<String>()
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            let meta = try? await backend.metadata(for: item.uid)
            if let rawSize = meta?.fileSize, rawSize > 0, rawSize <= Int(Int64.max / 2),
                let free = freeBytes(at: stagingDirectory), free < Int64(rawSize) * 2 + safetyMargin
            {
                throw ExportError.lowDisk
            }
            // The SDK currently downloads photos to a seekable file. Keep that bounded sidecar beside the staged
            // archive, stream it once into the ZIP, and erase it immediately.
            let sidecar = stagingDirectory.appendingPathComponent(
                ".encrypted-memories-export-\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: sidecar) }
            try await backend.writeOriginal(
                for: item.uid,
                to: sidecar,
                onProgress: { p in onProgress((Double(i) + p * 0.85) / total) }
            )
            try Task.checkCancellation()
            let size = Int64(try sidecar.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            if let free = freeBytes(at: stagingDirectory), free < size + safetyMargin { throw ExportError.lowDisk }
            let header = try fileHeader(sidecar)
            let ext = OriginalFileNaming.resolvedExtension(
                filename: meta?.filename,
                mimeType: meta?.mimeType,
                header: header,
                fallbackMediaType: item.mediaType,
                isVideo: item.isVideo
            )
            let base = OriginalFileNaming.exportFilename(
                metadataFilename: meta?.filename,
                fallbackBase: String(item.uid.nodeID.prefix(8)),
                ext: ext
            )
            try writer.addFile(name: uniqueName(base, used: &used), fileURL: sidecar)
            onProgress(Double(i + 1) / total)
        }
        try writer.finish()
        try installCompletedExport(stagedArchive, at: dest)
        success = true
    }

    /// `NSSavePanel` authorizes the selected file, but not UUID-named siblings. Foundation's replacement
    /// directory is the sandbox-safe location Apple provides for atomic-save staging on the destination volume.
    nonisolated private static func exportReplacementDirectory(for destination: URL) throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )
    }

    nonisolated private static func installCompletedExport(_ stagedFile: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagedFile)
        } else {
            try fileManager.moveItem(at: stagedFile, to: destination)
        }
    }

    nonisolated private static func fileHeader(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 64) ?? Data()
    }

    private func chooseZipDestination(suggestedName: String? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? "Encrypted Memories Export.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    nonisolated private static func freeBytes(at dir: URL) -> Int64? {
        (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private enum ExportError: Error { case lowDisk }

    private func chooseSingleDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    nonisolated private static func defaultName(_ item: PhotoItem, ext: String) -> String {
        let e = ext.isEmpty ? "jpg" : ext
        return "\(item.uid.nodeID.prefix(8)).\(e)"
    }

    nonisolated private static func defaultExtension(_ item: PhotoItem, metadata: PhotoMetadata?) -> String {
        // Resolve the extension from the filename, MIME type, or timeline media type.
        // No response header exists before the download starts.
        OriginalFileNaming.resolvedExtension(
            filename: metadata?.filename, mimeType: metadata?.mimeType, header: nil,
            fallbackMediaType: item.mediaType, isVideo: item.isVideo
        )
    }

    nonisolated private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        guard used.contains(name) else {
            used.insert(name)
            return name
        }
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            if !used.contains(candidate) {
                used.insert(candidate)
                return candidate
            }
            i += 1
        }
    }
}

/// Collapsible left sidebar - a native macOS sidebar `List` (Liquid-Glass vibrant material, native
/// selection): Proton smart filters (tags) on top, user albums below.
private struct SidebarView: View {
    let albums: [AlbumSummary]
    let isLoadingAlbums: Bool
    let albumCatalogFailed: Bool
    let sharedAlbums: [SharedAlbumSummary]
    let isLoadingSharedAlbums: Bool
    let sharedAlbumCatalogFailed: Bool
    let canLeaveSharedAlbum: Bool
    let thumbnailFeed: ThumbnailFeed
    let sourceAnalysisRevision: UInt64
    @Binding var selection: PhotoFilter
    let onRetryAlbums: () -> Void
    let onRetrySharedAlbums: () -> Void
    let onLeaveSharedAlbum: (SharedAlbumSummary) -> Void
    @State private var pendingSharedAlbumLeave: SharedAlbumSummary?

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let v = $0 { selection = v } })) {
            Section {
                Label("sidebar.all_photos", systemImage: "photo.on.rectangle.angled")
                    .tag(PhotoFilter.all)
                ForEach(PhotoTag.allCases, id: \.self) { tag in
                    Label(tag.title, systemImage: tag.systemImage)
                        .tag(PhotoFilter.tag(tag))
                }
                Label("sidebar.map", systemImage: "map")
                    .tag(PhotoFilter.map)
            }
            Section("sidebar.albums") {
                if isLoadingAlbums, albums.isEmpty {
                    Label("sidebar.albums_loading", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .foregroundStyle(.secondary)
                        .disabled(true)
                } else if albumCatalogFailed, albums.isEmpty {
                    Button(action: onRetryAlbums) {
                        Label("sidebar.albums_failed", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                } else if albums.isEmpty {
                    Label("sidebar.no_albums", systemImage: "tray")
                        .foregroundStyle(.secondary)
                        .disabled(true)
                }
                if albumCatalogFailed, !albums.isEmpty {
                    Button(action: onRetryAlbums) {
                        Label("sidebar.albums_failed", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(albums) { album in
                    Label(album.title, systemImage: "rectangle.stack")
                        .tag(PhotoFilter.album(id: album.id, title: album.title))
                }
            }
            Section(L10n.string("collections.section_shared_with_me")) {
                if isLoadingSharedAlbums, sharedAlbums.isEmpty {
                    Label(
                        L10n.string("collections.loading_shared_albums"),
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    .foregroundStyle(.secondary)
                    .disabled(true)
                } else if sharedAlbumCatalogFailed, sharedAlbums.isEmpty {
                    Button(action: onRetrySharedAlbums) {
                        Label(L10n.string("albums.shared_load_failed"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                } else if sharedAlbums.isEmpty {
                    Label(L10n.string("collections.empty_shared_albums"), systemImage: "person.2.crop.square.stack")
                        .foregroundStyle(.secondary)
                        .disabled(true)
                }
                ForEach(sharedAlbums) { album in
                    SharedAlbumSidebarRow(
                        album: album,
                        thumbnailFeed: thumbnailFeed,
                        sourceAnalysisRevision: sourceAnalysisRevision
                    )
                        .contextMenu {
                            if canLeaveSharedAlbum {
                                Button(L10n.string("albums.leave_shared_action"), role: .destructive) {
                                    pendingSharedAlbumLeave = album
                                }
                            }
                        }
                }
            }
            Section {
                Label("sidebar.recently_deleted", systemImage: "trash")
                    .tag(PhotoFilter.trash)
            }
            Section {
                Divider()
                SettingsLink {
                    Label("sidebar.settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .help("sidebar.settings")
                .accessibilityLabel("sidebar.settings")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)  // let the within-window glass (and the grid behind it) show through
        .confirmationDialog(
            L10n.string("albums.leave_shared_title"),
            isPresented: Binding(
                get: { pendingSharedAlbumLeave != nil },
                set: { if !$0 { pendingSharedAlbumLeave = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("albums.leave_shared_action"), role: .destructive) {
                guard let album = pendingSharedAlbumLeave else { return }
                onLeaveSharedAlbum(album)
                pendingSharedAlbumLeave = nil
            }
            Button(L10n.string("action.cancel"), role: .cancel) {
                pendingSharedAlbumLeave = nil
            }
        } message: {
            Text(L10n.string("albums.leave_shared_message"))
        }
    }
}

private struct SharedAlbumSidebarRow: View {
    let album: SharedAlbumSummary
    let thumbnailFeed: ThumbnailFeed
    let sourceAnalysisRevision: UInt64
    @State private var coverImage: NSImage?
    @State private var loadedCoverUID: PhotoUID?

    private struct CoverLoadKey: Equatable {
        let uid: PhotoUID?
        let analysisRevision: UInt64
    }

    private var coverUID: PhotoUID? { album.coverPhotoUID }

    private var details: String {
        var parts: [String] = []
        if let owner = album.owner, !owner.isEmpty {
            parts.append(L10n.string("albums.shared_owner \(owner)"))
        }
        parts.append(L10n.string("albums.photo_count \(album.photoCount)"))
        if album.isSharedByURL {
            parts.append(L10n.string("albums.shared_via_link"))
        }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                if let coverImage {
                    Image(nsImage: coverImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.2.crop.square.stack")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .task(id: CoverLoadKey(uid: coverUID, analysisRevision: sourceAnalysisRevision)) {
            if loadedCoverUID != coverUID {
                coverImage = nil
                loadedCoverUID = coverUID
            }
            guard coverImage == nil else { return }
            guard let coverUID else { return }
            coverImage = thumbnailFeed.memoryImage(for: coverUID)
            if coverImage == nil {
                coverImage = await thumbnailFeed.analysisImage(for: coverUID)
            }
        }
    }
}
