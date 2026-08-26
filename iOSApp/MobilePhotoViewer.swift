import AVFoundation
import AVKit
import AlbumCore
import DesignSystemCore
import MapUIKitAdapter
import MediaByteCache
import MediaCacheUIKitAdapter
import MediaLocationCore
import PhotoViewerCore
import PhotoViewerUIKitAdapter
import PhotosCore
import SwiftUI
import UIKit

/// Native full-screen photo/video viewer. Paging + chrome live here (pure presentation); the media decoding,
/// titles, video-playback and pinch-to-close semantics come from shared `PhotoViewerCore` and the shared
/// backend - no viewer business logic is reimplemented per platform.
struct MobilePhotoViewer: View {
    let items: [PhotoItem]
    let startIndex: Int
    let context: ViewerCollectionContext
    let libraryModel: MobileLibraryModel
    let viewerRouter: MobileViewerRouter
    private let pageIndex: ViewerPageIndex

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var index: Int
    @State private var chromeVisible = true
    @State private var burstSelection = BurstSelectionModel()
    @State private var selection = MobileGridSelectionController()
    @State private var isRestoring = false
    @State private var showRestoreError = false
    @State private var showFavoriteError = false
    @State private var favoriteTask: Task<Void, Never>?
    @State private var favoriteRequestGeneration: UInt64 = 0
    @State private var restoreTask: Task<Void, Never>?
    @State private var restoreRequestGeneration: UInt64 = 0
    @State private var showInfo = false
    @State private var metadataLoadState: PhotoMetadataLoadState = .idle
    @State private var metadataRequestGeneration: UInt64 = 0
    @State private var albumTitles: [String] = []
    @State private var isLoadingAlbumMemberships = false
    @State private var albumMembershipsLoadFailed = false
    /// The title/info metadata request already resolves the authoritative link MIME type. Feed that
    /// result into the page router too, so a video mislabeled by incomplete timeline metadata switches to
    /// native playback instead of leaving the image page spinning forever.
    @State private var resolvedMediaKinds: [PhotoUID: MediaKind] = [:]
    @State private var titleMetadataState: ViewerTitleMetadataState = .resolving
    @State private var titleMetadataCoordinator: ViewerTitleMetadataCoordinator
    /// Ties the sub-selection to its library page so an index change can never flash the previous page's burst.
    @State private var burstBaseUID: PhotoUID?
    /// Bounded, shared image loader for the pages (thumbnail to screen-bounded preview, off-main and cached).
    /// the shared `PhotoViewerUIKitAdapter` store, wired to the feed's RAM tier via a closure so the
    /// adapter never depends on a concrete feed type.
    @State private var imageStore: UIKitViewerImageStore

    init(
        items: [PhotoItem],
        startIndex: Int,
        context: ViewerCollectionContext,
        libraryModel: MobileLibraryModel,
        viewerRouter: MobileViewerRouter
    ) {
        self.items = items
        self.startIndex = startIndex
        self.context = context
        self.libraryModel = libraryModel
        self.viewerRouter = viewerRouter
        self.pageIndex = ViewerPageIndex(orderedUIDs: items.map(\.uid))
        _index = State(initialValue: min(max(startIndex, 0), max(items.count - 1, 0)))
        _titleMetadataCoordinator = State(
            initialValue: ViewerTitleMetadataCoordinator(
                metadataProvider: libraryModel.backend,
                placeNameResolver: NativePlaceNameResolver.shared
            ))
        let feed = libraryModel.thumbnailFeed
        // Seed/reuse the E2EE originals cache via the shared helper, injected as a closure so the viewer
        // adapter stays decoupled from the cache layer. When the viewer decrypts an original (a no-preview
        // item), it lands in the encrypted cache and later opens / shares reuse it before the network.
        let originalFetch: (@Sendable (PhotoUID) async throws -> Data)?
        if let backend = libraryModel.backend, let originals = libraryModel.originalsCache {
            let provider = EncryptedOriginalProvider(
                media: backend, cache: originals,
                policy: .persisting(capBytes: libraryModel.originalsCacheCapBytes)
            )
            originalFetch = { try await provider.originalData(for: $0) }
        } else {
            originalFetch = nil
        }
        _imageStore = State(
            initialValue: UIKitViewerImageStore(
                thumbnailProvider: { feed?.memoryImage(for: $0) },
                media: libraryModel.backend,
                originalDataOverride: originalFetch))
    }

    var body: some View {
        MobileViewerChromeOverlay(showsChrome: chromeVisible) {
            ZStack {
                Color.black.ignoresSafeArea()

                // UIKit pager (UIPageViewController) instead of SwiftUI's page TabView, because rotation
                // must preserve the current page during the size transition.
                // The SwiftUI pager keeps its width-bound content offset and page size through a device rotation,
                // so the photo rotated displaced in a corner and snapped to centre only afterwards (a rebuild via
                // `.id` was a hard cut instead). UIPageViewController participates in the size transition and keeps
                // the current page centred through the whole rotation - the Photos-app behavior.
                MobileViewerPager(count: items.count, index: $index) { i, isCurrent in
                    let item = displayedItem(at: i)
                    MobileViewerPage(
                        item: item,
                        isCurrent: isCurrent,
                        showsChrome: chromeVisible,
                        resolvedMediaKind: resolvedMediaKinds[item.uid],
                        libraryModel: libraryModel,
                        imageStore: imageStore,
                        onToggleChrome: {
                            withAnimation(
                                MobileViewerMotionPolicy.animation(
                                    .easeInOut(duration: 0.2), reduceMotion: reduceMotion
                                )
                            ) {
                                chromeVisible.toggle()
                            }
                        },
                        onCloseRequested: { dismiss() }
                    )
                    .id(item.uid)
                }
                .ignoresSafeArea()
            }
        } topChrome: {
            viewerTopChrome
                .zIndex(2)
        } bottomChrome: {
            viewerBottomChrome
                .zIndex(3)
        }
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .task {
            // Register the viewer's transient display cache with the shared memory governor (identity-keyed:
            // a newly opened viewer replaces the previous registration; the weak capture makes a dismissed
            // viewer's handler a no-op). Under `.minimal` the store purges every page except the visible one.
            UIKitMemoryPressureCoordinator.shared.attach(imageStore, key: "viewerImageStore") {
                [weak imageStore] tier in
                imageStore?.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
            }
        }
        .task(id: currentBaseItem?.uid) {
            guard let currentBaseItem else { return }
            await loadBurst(for: currentBaseItem)
        }
        .task(id: metadataTaskID) {
            await resolveCurrentTitleMetadata()
        }
        .sheet(isPresented: $showInfo) {
            if let item = currentDisplayedItem {
                MobileViewerInfoSheet(
                    item: item,
                    metadataLoadState: metadataLoadState,
                    albumTitles: albumTitles,
                    canLoadAlbumMemberships: libraryModel.facade?.albums != nil,
                    isLoadingAlbumMemberships: isLoadingAlbumMemberships,
                    albumMembershipsLoadFailed: albumMembershipsLoadFailed,
                    placeName: titleMetadataState.resolution?.placeName,
                    onRetry: retryCurrentMetadata
                )
            }
        }
        .mobileSharePresentation(selection: selection)
        .mobileSelectionAlerts(
            selection: selection,
            trashTitle: String(localized: "viewer.trash_title"),
            trashMessage: String(localized: "viewer.trash_message"),
            trashConfirm: String(localized: "viewer.trash_confirm")
        ) { confirmMoveToTrash() }
        .alert(String(localized: "viewer.restore_failed_title"), isPresented: $showRestoreError) {
            Button(L10n.string("action.ok"), role: .cancel) {}
        } message: {
            Text(String(localized: "viewer.restore_failed_message"))
        }
        .alert(String(localized: "viewer.favorite_failed_title"), isPresented: $showFavoriteError) {
            Button(L10n.string("action.ok"), role: .cancel) {}
        } message: {
            Text(String(localized: "viewer.favorite_failed_message"))
        }
        .onChange(of: currentDisplayedItem?.uid) { _, _ in
            cancelViewerMutationPresentation()
        }
        .onDisappear {
            cancelViewerMutationPresentation()
            titleMetadataCoordinator.cancelAll()
        }
        .animation(
            MobileViewerMotionPolicy.animation(.smooth(duration: 0.24), reduceMotion: reduceMotion),
            value: burstSelection.hasFilmstrip
        )
    }

    /// One stable Apple-Photos-style header stays mounted while paging between photos, Live Photos, and videos.
    /// Fixed-width edge buttons leave a measured, bounded center pill even on the smallest supported iPhone.
    private var viewerTopChrome: some View {
        VStack(spacing: 6) {
            viewerHeader

            if currentDisplayedItem?.isLivePhoto == true {
                viewerLiveIndicator
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var viewerBottomChrome: some View {
        let profile = chromeLayoutProfile
        return VStack(spacing: profile.rowSpacing) {
            if burstBelongsToCurrentPage, burstSelection.hasFilmstrip {
                MobileBurstFilmstrip(
                    selection: burstSelection,
                    feed: libraryModel.thumbnailFeed,
                    onSelect: selectBurstIndex
                )
                .frame(maxHeight: 124)
            }

            MobileViewerFilmstrip(
                items: items,
                selectedUID: currentBaseItem?.uid,
                feed: libraryModel.thumbnailFeed,
                itemSide: min(46, profile.filmstripHeight),
                onSelect: selectPage
            )
            .frame(height: profile.filmstripHeight)

            if profile.showsBottomActionRow {
                viewerActionRow
                    .frame(height: profile.controlSide)
            }
        }
        .padding(.horizontal, MobileViewerBottomLayout.horizontalPadding)
        .safeAreaPadding(.bottom, profile.bottomPadding)
        .frame(maxWidth: .infinity)
    }

    private var isCompactLandscape: Bool { verticalSizeClass == .compact }
    private var chromeLayoutProfile: ViewerChromeLayoutProfile {
        MobileViewerBottomLayout.profile(compactLandscape: isCompactLandscape)
    }

    @ViewBuilder
    private var viewerHeader: some View {
        if isCompactLandscape {
            compactLandscapeHeader
        } else {
            regularViewerHeader
        }
    }

    private var regularViewerHeader: some View {
        GeometryReader { proxy in
            ZStack {
                viewerTitlePill
                    .frame(width: MobileViewerHeaderLayout.titleWidth(containerWidth: proxy.size.width))

                HStack {
                    viewerBackButton
                    Spacer()
                    viewerActionButton
                }
                .padding(.horizontal, MobileViewerHeaderLayout.horizontalPadding)
            }
        }
        .frame(height: 44)
        .padding(.top, 10)
    }

    private var compactLandscapeHeader: some View {
        GeometryReader { proxy in
            ZStack {
                viewerTitlePill
                    .frame(width: min(280, max(160, proxy.size.width - 320)))

                HStack {
                    HStack(spacing: 0) {
                        compactActionButton(symbol: "chevron.left", label: String(localized: "viewer.close_a11y")) {
                            dismiss()
                        }
                        compactActionButton(
                            symbol: "square.and.arrow.up",
                            label: String(localized: "viewer.share_action"),
                            disabled: currentDisplayedItem == nil || selection.isBusy,
                            action: shareCurrentItem
                        )
                        compactFavoriteButton
                    }
                    .protonGlass(in: Capsule())

                    Spacer(minLength: 16)

                    HStack(spacing: 0) {
                        compactActionButton(
                            symbol: "info.circle",
                            label: String(localized: "viewer.info_action"),
                            disabled: currentDisplayedItem == nil
                        ) { showInfo = true }
                        compactActionButton(
                            symbol: viewerMutationAction == .restore ? "arrow.uturn.backward" : "trash",
                            label: viewerMutationAction == .restore
                                ? String(localized: "viewer.restore_action")
                                : String(localized: "viewer.move_to_trash_action"),
                            disabled: currentDisplayedItem == nil || isRestoring || selection.isBusy,
                            action: requestViewerMutation
                        )
                        compactActionMenu
                    }
                    .protonGlass(in: Capsule())
                }
                .padding(.horizontal, MobileViewerHeaderLayout.horizontalPadding)
            }
        }
        .frame(height: ViewerChromeLayoutProfile.compactLandscape.controlSide)
        .padding(.top, 6)
    }

    private func compactActionButton(
        symbol: String,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var compactFavoriteButton: some View {
        let uid = currentDisplayedItem?.uid
        let favorite = uid.map { libraryModel.favoriteUIDs.contains($0) } ?? false
        let busy = uid.map { libraryModel.favoriteMutationsInFlight.contains($0) } ?? false
        return Button {
            guard let uid else { return }
            toggleFavorite(uid)
        } label: {
            Group {
                if busy {
                    ProgressView().tint(Color.primary)
                } else {
                    Image(systemName: favorite ? "heart.fill" : "heart")
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
        }
        .disabled(uid == nil || busy)
        .accessibilityLabel(
            favorite
                ? String(localized: "viewer.remove_favorite_action")
                : String(localized: "viewer.favorite_action")
        )
    }

    private var compactActionMenu: some View {
        Menu {
            viewerActionMenu
        } label: {
            Group {
                if selection.isBusy || isRestoring {
                    ProgressView().tint(Color.primary)
                } else {
                    Image(systemName: "ellipsis")
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
        }
        .disabled(selection.isBusy || isRestoring)
        .accessibilityLabel(String(localized: "viewer.more_actions_a11y"))
    }

    private var viewerBackButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(
                    width: MobileViewerHeaderLayout.buttonWidth,
                    height: MobileViewerHeaderLayout.buttonWidth
                )
                .protonGlass(in: Circle())
        }
        .accessibilityLabel(String(localized: "viewer.close_a11y"))
    }

    @ViewBuilder
    private var viewerActionButton: some View {
        if currentDisplayedItem != nil {
            Menu {
                viewerActionMenu
            } label: {
                Group {
                    if selection.isBusy || isRestoring {
                        ProgressView().tint(Color.primary)
                    } else {
                        Image(systemName: "ellipsis")
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(
                    width: MobileViewerHeaderLayout.buttonWidth,
                    height: MobileViewerHeaderLayout.buttonWidth
                )
                .protonGlass(in: Circle())
            }
            .disabled(selection.isBusy || isRestoring)
            .accessibilityLabel(String(localized: "viewer.more_actions_a11y"))
        } else {
            Color.clear.frame(
                width: MobileViewerHeaderLayout.buttonWidth,
                height: MobileViewerHeaderLayout.buttonWidth
            )
        }
    }

    private var viewerTitlePill: some View {
        viewerTitle
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .protonGlass(in: Capsule())
            .contentTransition(.interpolate)
    }

    @ViewBuilder
    private var viewerTitle: some View {
        if let current = currentDisplayedItem {
            let title = ViewerTitleFormatter.make(
                captureDate: current.captureTime,
                index: index,
                total: items.count,
                locationName: titleMetadataState.resolution?.placeName,
                locationIsResolving: titleMetadataState.shouldReservePlaceNameLine(
                    hasKnownLocation: libraryModel.locationIndex.hasKnownLocation(current.uid)
                ),
                filename: metadataLoadState.metadata?.filename
            )
            VStack(spacing: 1) {
                Text(title.line1)
                    .font(.subheadline.weight(.semibold))
                    .opacity(title.reservesLocationLine ? 0 : 1)
                Text(title.line2)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .truncationMode(.tail)
        }
    }

    private var viewerLiveIndicator: some View {
        HStack {
            MobileLiveBadge()
            Spacer()
        }
        .padding(.horizontal, 16)
        .allowsHitTesting(false)
    }

    private var viewerActionRow: some View {
        HStack(spacing: MobileViewerBottomLayout.rowSpacing) {
            Button(action: shareCurrentItem) {
                Group {
                    if selection.isBusy {
                        ProgressView().tint(Color.primary)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(
                    width: MobileViewerBottomLayout.actionButtonSize,
                    height: MobileViewerBottomLayout.actionButtonSize
                )
                .protonGlass(in: Circle())
            }
            .disabled(currentDisplayedItem == nil || selection.isBusy)
            .accessibilityLabel(String(localized: "viewer.share_action"))

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                viewerFavoriteButton
                viewerInfoButton
            }
            .frame(width: MobileViewerBottomLayout.centerPillWidth, height: MobileViewerBottomLayout.actionButtonSize)
            .protonGlass(in: Capsule())

            Spacer(minLength: 0)

            Button(action: requestViewerMutation) {
                Group {
                    if isRestoring || selection.isTrashing {
                        ProgressView().tint(Color.primary)
                    } else {
                        Image(systemName: viewerMutationAction == .restore ? "arrow.uturn.backward" : "trash")
                    }
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(
                    width: MobileViewerBottomLayout.actionButtonSize,
                    height: MobileViewerBottomLayout.actionButtonSize
                )
                .protonGlass(in: Circle())
            }
            .disabled(currentDisplayedItem == nil || isRestoring || selection.isBusy)
            .accessibilityLabel(
                viewerMutationAction == .restore
                    ? String(localized: "viewer.restore_action")
                    : String(localized: "viewer.move_to_trash_action")
            )
        }
    }

    private var viewerFavoriteButton: some View {
        let uid = currentDisplayedItem?.uid
        let favorite = uid.map { libraryModel.favoriteUIDs.contains($0) } ?? false
        let busy = uid.map { libraryModel.favoriteMutationsInFlight.contains($0) } ?? false
        return Button {
            guard let uid else { return }
            toggleFavorite(uid)
        } label: {
            Group {
                if busy {
                    ProgressView().tint(Color.primary)
                } else {
                    Image(systemName: favorite ? "heart.fill" : "heart")
                }
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(
                width: MobileViewerBottomLayout.centerPillWidth / 2, height: MobileViewerBottomLayout.actionButtonSize)
        }
        .disabled(uid == nil || busy)
        .accessibilityLabel(
            favorite
                ? String(localized: "viewer.remove_favorite_action")
                : String(localized: "viewer.favorite_action")
        )
    }

    private var viewerInfoButton: some View {
        Button {
            showInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(
                    width: MobileViewerBottomLayout.centerPillWidth / 2,
                    height: MobileViewerBottomLayout.actionButtonSize
                )
        }
        .disabled(currentDisplayedItem == nil)
        .accessibilityLabel(String(localized: "viewer.info_action"))
    }

    @ViewBuilder
    private var viewerActionMenu: some View {
        if !albumTitles.isEmpty {
            Section(L10n.string("infopanel.albums")) {
                ForEach(albumTitles, id: \.self) { title in
                    Label(title, systemImage: "rectangle.stack")
                }
            }
        }
        Button {
            shareCurrentItem()
        } label: {
            Label(String(localized: "viewer.share_action"), systemImage: "square.and.arrow.up")
        }

        Divider()

        if viewerMutationAction == .restore {
            Button {
                requestViewerMutation()
            } label: {
                Label(String(localized: "viewer.restore_action"), systemImage: "arrow.uturn.backward")
            }
        } else {
            Button(role: .destructive) {
                requestViewerMutation()
            } label: {
                Label(String(localized: "viewer.move_to_trash_action"), systemImage: "trash")
            }
        }
    }

    private var viewerMutationAction: ViewerMutationAction {
        ViewerMutationPolicy.action(for: context)
    }

    private struct MetadataTaskID: Equatable {
        let uid: PhotoUID?
        let generation: UInt64
    }

    private var metadataTaskID: MetadataTaskID {
        MetadataTaskID(uid: currentDisplayedItem?.uid, generation: metadataRequestGeneration)
    }

    private func resolveCurrentTitleMetadata() async {
        titleMetadataCoordinator.prepare(items: items, around: index)
        metadataLoadState = .idle
        albumTitles = []
        albumMembershipsLoadFailed = false
        guard let item = currentDisplayedItem else { return }
        let uid = item.uid
        titleMetadataState = titleMetadataCoordinator.state(for: uid)
        metadataLoadState = .loading
        isLoadingAlbumMemberships = libraryModel.facade?.albums != nil
        async let memberships = resolvedAlbumTitles(for: uid)
        async let titleResolution = titleMetadataCoordinator.resolve(item)
        let membershipResult = await memberships
        let resolution = await titleResolution
        guard !Task.isCancelled, currentDisplayedItem?.uid == uid else { return }
        applyAlbumMembershipResult(membershipResult)
        titleMetadataState = .resolved(resolution)
        guard let metadata = resolution.metadata else {
            metadataLoadState = .failed
            return
        }
        metadataLoadState = .loaded(metadata)
        let resolvedKind = VideoContentSniffer.kind(mimeType: metadata.mimeType)
        if resolvedKind != .unknown {
            resolvedMediaKinds[uid] = resolvedKind
        }
    }

    private func retryCurrentMetadata() {
        guard let uid = currentDisplayedItem?.uid else { return }
        titleMetadataCoordinator.invalidate(uid)
        metadataRequestGeneration &+= 1
    }

    private func resolvedAlbumTitles(for uid: PhotoUID) async -> Result<[String], Error>? {
        guard let repository = libraryModel.facade?.albums else { return nil }
        do {
            return .success(try await repository.albumMembershipTitles(for: uid))
        } catch {
            return .failure(error)
        }
    }

    @MainActor
    private func applyAlbumMembershipResult(_ result: Result<[String], Error>?) {
        isLoadingAlbumMemberships = false
        switch result {
        case .success(let titles):
            albumTitles = titles
            albumMembershipsLoadFailed = false
        case .failure:
            albumTitles = []
            albumMembershipsLoadFailed = true
        case nil:
            albumTitles = []
            albumMembershipsLoadFailed = false
        }
    }

    private func shareCurrentItem() {
        guard let item = currentDisplayedItem, let backend = libraryModel.backend else { return }
        let items = burstBelongsToCurrentPage ? burstSelection.exportItems(current: item) : [item]
        selection.startShare(
            items: items, backend: backend,
            failureMessage: String(localized: "viewer.share_failed")
        )
    }

    private func requestViewerMutation() {
        guard let item = currentDisplayedItem else { return }
        switch viewerMutationAction {
        case .moveToTrash:
            selection.selected = [item.uid]
            selection.showTrashConfirm = true
        case .restore:
            restore(item)
        }
    }

    private func confirmMoveToTrash() {
        guard let item = currentDisplayedItem else { return }
        selection.performTrash(failureMessage: String(localized: "viewer.trash_failed")) { uids in
            try await libraryModel.trashItems(uids)
            viewerRouter.noteCompletedMutation(uid: item.uid)
            dismiss()
        }
    }

    private func restore(_ item: PhotoItem) {
        guard !isRestoring else { return }
        restoreRequestGeneration &+= 1
        let requestGeneration = restoreRequestGeneration
        let uid = item.uid
        isRestoring = true
        restoreTask = Task { @MainActor in
            do {
                try await libraryModel.restoreItems([item])
                // The remote restore is authoritative even if the viewer paged or disappeared while waiting.
                // Always reconcile the source route; the request generation gates presentation only.
                viewerRouter.noteCompletedMutation(uid: uid)
                restoreTask = nil
                isRestoring = false
                guard requestGeneration == restoreRequestGeneration,
                    currentDisplayedItem?.uid == uid
                else { return }
                dismiss()
            } catch is CancellationError {
                restoreTask = nil
                isRestoring = false
            } catch {
                restoreTask = nil
                isRestoring = false
                guard requestGeneration == restoreRequestGeneration,
                    currentDisplayedItem?.uid == uid
                else { return }
                showRestoreError = true
            }
        }
    }

    private func toggleFavorite(_ uid: PhotoUID) {
        favoriteTask?.cancel()
        favoriteRequestGeneration &+= 1
        let requestGeneration = favoriteRequestGeneration
        favoriteTask = Task { @MainActor in
            let succeeded = await libraryModel.toggleFavorite(uid)
            guard !Task.isCancelled,
                requestGeneration == favoriteRequestGeneration,
                currentDisplayedItem?.uid == uid
            else { return }
            favoriteTask = nil
            if !succeeded {
                showFavoriteError = true
            }
        }
    }

    private func cancelViewerMutationPresentation() {
        favoriteRequestGeneration &+= 1
        favoriteTask?.cancel()
        favoriteTask = nil
        restoreRequestGeneration &+= 1
        showFavoriteError = false
        showRestoreError = false
    }

    private var currentBaseItem: PhotoItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    @MainActor
    private func selectPage(_ uid: PhotoUID) {
        guard let selected = pageIndex.index(of: uid) else { return }
        guard selected != index else { return }
        index = selected
    }

    private var burstBelongsToCurrentPage: Bool {
        burstBaseUID == currentBaseItem?.uid
    }

    private var currentDisplayedItem: PhotoItem? {
        guard let base = currentBaseItem else { return nil }
        return burstBelongsToCurrentPage ? burstSelection.current(fallback: base) : base
    }

    private func displayedItem(at pageIndex: Int) -> PhotoItem {
        let base = items[pageIndex]
        guard pageIndex == index, burstBaseUID == base.uid else { return base }
        return burstSelection.current(fallback: base)
    }

    @MainActor private func loadBurst(for item: PhotoItem) async {
        burstBaseUID = item.uid
        burstSelection.reset()
        burstSelection.seedKnownGroup(
            for: item,
            knownItems: pageIndex.items(withUIDs: item.burstMemberUIDs, from: items)
        )
        guard let provider = libraryModel.backend,
            burstSelection.beginLoadingIfCandidate(item)
        else { return }
        do {
            let group = try await provider.burstGroup(containing: item.uid)
            guard !Task.isCancelled, currentBaseItem?.uid == item.uid else { return }
            withAnimation(
                MobileViewerMotionPolicy.animation(
                    .smooth(duration: 0.24), reduceMotion: reduceMotion
                )
            ) {
                burstSelection.applyLoadedGroup(group, containing: item)
            }
        } catch {
            guard !Task.isCancelled, currentBaseItem?.uid == item.uid else { return }
            burstSelection.failLoading()
        }
    }

    @MainActor private func selectBurstIndex(_ newIndex: Int) {
        withAnimation(
            MobileViewerMotionPolicy.animation(
                .easeInOut(duration: 0.16), reduceMotion: reduceMotion
            )
        ) {
            _ = burstSelection.selectIndex(newIndex)
        }
    }
}

/// Native mobile presentation of the shared burst selection state. It overlays the media rather than changing
/// safe-area/layout geometry, so appearing or changing selection never makes the fitted photo jump.
private struct MobileBurstFilmstrip: View {
    let selection: BurstSelectionModel
    let feed: UIKitThumbnailFeed?
    let onSelect: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var position: Int { (selection.selectedIndex ?? 0) + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                selection.isLoading
                    ? L10n.string("viewer.burst_loading")
                    : L10n.string("viewer.burst_badge \(position) \(selection.items.count)"),
                systemImage: "square.stack.3d.down.right"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 2)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(selection.items.enumerated()), id: \.element.uid) { index, item in
                            Button {
                                onSelect(index)
                            } label: {
                                MobileBurstThumbnail(
                                    item: item,
                                    selected: selection.selectedIndex == index,
                                    feed: feed
                                )
                            }
                            .buttonStyle(.plain)
                            .id(item.uid)
                            .accessibilityLabel(
                                L10n.string("viewer.burst_badge \(index + 1) \(selection.items.count)")
                            )
                            .accessibilityAddTraits(selection.selectedIndex == index ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selection.selectedIndex, initial: true) { _, selected in
                    guard let selected, selection.items.indices.contains(selected) else { return }
                    withAnimation(
                        MobileViewerMotionPolicy.animation(
                            .easeInOut(duration: 0.2), reduceMotion: reduceMotion
                        )
                    ) {
                        proxy.scrollTo(selection.items[selected].uid, anchor: .center)
                    }
                }
            }
            .frame(height: 54)
            .accessibilityLabel(L10n.string("viewer.burst_filmstrip_label"))
        }
        .padding(8)
        .protonGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct MobileBurstThumbnail: View {
    let item: PhotoItem
    let selected: Bool
    let feed: UIKitThumbnailFeed?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white, lineWidth: selected ? 3 : 0)
        }
        .scaleEffect(selected ? 1 : 0.92)
        .animation(
            MobileViewerMotionPolicy.animation(.smooth(duration: 0.2), reduceMotion: reduceMotion),
            value: selected
        )
        .task(id: item.uid) {
            image = feed?.memoryImage(for: item.uid)
            if image == nil { image = await feed?.image(for: item.uid) }
        }
    }
}

/// Native horizontal photo pager: `UIPageViewController(.scroll)` hosting the SwiftUI pages. Chosen over
/// SwiftUI's `TabView(.page)` because it participates in the device-rotation size transition - the current
/// page stays centred and refits throughout the rotation animation instead of snapping afterwards. Selection
/// syncs both ways via the `index` binding; `isCurrent` is re-injected into every live page on change, so
/// pages keep their bounded load/teardown behavior (current page only).
private struct MobileViewerPager<Page: View>: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int
    @ViewBuilder let page: (Int, Bool) -> Page

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 12]  // the small black gutter between pages, like Photos
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        pvc.setViewControllers([context.coordinator.pageController(at: index)], direction: .forward, animated: false)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // An external index change jumps to that page; user swipes return through the delegate.
        if let visible = (pvc.viewControllers?.first as? HostedPage)?.pageIndex, visible != index {
            pvc.setViewControllers(
                [context.coordinator.pageController(at: index)],
                direction: visible < index ? .forward : .reverse, animated: false)
        }
        context.coordinator.refreshLivePages()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Hosts one page and remembers which index it shows (the pager's data source is index-based).
    final class HostedPage: UIHostingController<AnyView> {
        let pageIndex: Int
        init(index: Int, root: AnyView) {
            self.pageIndex = index
            super.init(rootView: root)
            view.backgroundColor = .clear  // never flash the hosting default background between pages
        }
        @available(*, unavailable)
        @MainActor required dynamic init?(coder: NSCoder) { fatalError("not supported") }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: MobileViewerPager
        /// Live pages by index, kept to a window around the requested page. Evicted pages are still retained
        /// by UIPageViewController while on screen; we only lose SwiftUI-state reuse, and the viewer store's
        /// cache makes a re-created page's image instant.
        private var live: [Int: HostedPage] = [:]

        init(parent: MobileViewerPager) { self.parent = parent }

        func pageController(at i: Int) -> HostedPage {
            if let vc = live[i] { return vc }
            let vc = HostedPage(index: i, root: AnyView(parent.page(i, i == parent.index)))
            live[i] = vc
            live = live.filter { abs($0.key - i) <= 2 }
            return vc
        }

        /// Re-inject `isCurrent` into every live page after a selection change, preserving the pages'
        /// current-only load/teardown gating.
        func refreshLivePages() {
            for (i, vc) in live { vc.rootView = AnyView(parent.page(i, i == parent.index)) }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let i = (viewController as? HostedPage)?.pageIndex, i > 0 else { return nil }
            return pageController(at: i - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let i = (viewController as? HostedPage)?.pageIndex, i < parent.count - 1 else { return nil }
            return pageController(at: i + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController], transitionCompleted completed: Bool
        ) {
            guard completed, let i = (pageViewController.viewControllers?.first as? HostedPage)?.pageIndex else {
                return
            }
            parent.index = i  // The binding update refreshes live pages and their current state.
        }
    }
}

/// A single viewer page - a zoomable image, or a native video player for video items.
private struct MobileViewerPage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let showsChrome: Bool
    let resolvedMediaKind: MediaKind?
    let libraryModel: MobileLibraryModel
    let imageStore: UIKitViewerImageStore
    let onToggleChrome: () -> Void
    let onCloseRequested: () -> Void

    var body: some View {
        if MobileViewerMediaRoute.isVideo(item: item, resolvedKind: resolvedMediaKind) {
            MobileVideoPage(
                item: item,
                isCurrent: isCurrent,
                showsChrome: showsChrome,
                libraryModel: libraryModel,
                onToggleChrome: onToggleChrome,
                onCloseRequested: onCloseRequested
            )
        } else {
            MobileImagePage(
                item: item,
                isCurrent: isCurrent,
                imageStore: imageStore,
                streamer: libraryModel.backend,
                onToggleChrome: onToggleChrome,
                onCloseRequested: onCloseRequested
            )
        }
    }
}

/// Staged, bounded page loading (thumbnail to screen-bounded display image): the grid thumbnail shows instantly,
/// then, for the current page only, a mid-size preview or bounded original fallback is fetched and decoded
/// off-main to a screen-bounded size and swapped in. Swipe-preview neighbours never fetch/decode (no fan-out),
/// and swiping away cancels an in-flight load (the `.task(id:)` re-runs on the isCurrent flip). No full-resolution
/// decode just because a page appeared.
private struct MobileImagePage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let imageStore: UIKitViewerImageStore
    /// The shared streamer used to prepare a Live Photo's paired motion clip after a user request (nil for non-Live items).
    let streamer: (any VideoStreamProvider)?
    let onToggleChrome: () -> Void
    let onCloseRequested: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    /// The displayed photo rect (aspect-fit area, zoom/pan-transformed) in page coordinates, reported live by
    /// the zoomable scroll view. Anchors the motion overlay to the photo, not the viewer.
    @State private var photoFrame: CGRect?
    /// In-flight zoom-tier decode - replaced (cancelling the old fetch) when the zoom settles elsewhere.
    @State private var zoomDecodeTask: Task<Void, Never>?
    /// The decode cap of the image currently displayed (0 = grid thumbnail). Tier assignments are gated on
    /// `newCap >= displayedCap`, so a slower base-tier load cannot replace a sharper zoom decode that
    /// landed while it was still in flight.
    @State private var displayedCap = 0
    /// Real decoded pixels currently on screen. Request caps alone are not quality evidence: the opening
    /// transition can briefly report a thumbnail-sized viewport and produce a smaller preview than the grid image.
    @State private var displayedLongestPixelSide = 0
    /// Live Photos keep the loading presentation until original bytes have produced the bounded sharp still.
    /// Regular photos retain the existing preview-first behavior and fetch original bytes only for settled zoom.
    @State private var isFullResolutionStillReady = false
    @State private var didFullResolutionStillFail = false
    /// Shared Live Photo motion controller for the current page.
    @State private var motion = LivePhotoMotionController()
    /// Actual page viewport, including iPad split-view and future resizable form factors. A global
    /// screen bound over-decodes small windows and becomes wrong after a live resize.
    @State private var viewportSize: CGSize = .zero

    /// Shared still-to-motion transition timing.
    private let transition = ViewerMediaTransitionStyle.standard
    var body: some View {
        ZStack {
            if let image {
                MobileZoomableImage(
                    image: image,
                    reduceMotion: reduceMotion,
                    onSingleTap: onToggleChrome,
                    onCloseRequested: onCloseRequested,
                    onMotionStart: item.isLivePhoto
                        ? {
                            motion.play(for: item, streamer: streamer) { isCurrent }
                        } : nil,
                    onMotionStop: item.isLivePhoto ? { motion.stop() } : nil,
                    onPhotoFrameChanged: { photoFrame = $0 },
                    onZoomSettled: { loadZoomedDecodeIfNeeded(zoom: $0) }
                )
            } else if livePhotoReadiness == .notApplicable {
                ProgressView().tint(.white)
            }

            // The paired motion clip, crossfaded in over the still while the press is held (once preloaded).
            // Framed to the displayed photo rect (zoom- and pan-transformed), so a zoomed-in Live Photo plays
            // its motion at the same zoom/position as the still - never an unzoomed clip floating on top.
            if item.isLivePhoto, let player = motion.player {
                if let pf = photoFrame {
                    MobileMotionPlayerLayer(player: player)
                        .frame(width: pf.width, height: pf.height)
                        .position(x: pf.midX, y: pf.midY)
                        .allowsHitTesting(false)
                        .opacity(motion.isPlaying ? 1 : 0)
                        .animation(
                            MobileViewerMotionPolicy.animation(
                                .easeInOut(duration: transition.opacityDuration), reduceMotion: reduceMotion
                            ),
                            value: motion.isPlaying
                        )
                        .zIndex(1)
                } else {
                    MobileMotionPlayerLayer(player: player)
                        .allowsHitTesting(false)
                        .opacity(motion.isPlaying ? 1 : 0)
                        .animation(
                            MobileViewerMotionPolicy.animation(
                                .easeInOut(duration: transition.opacityDuration), reduceMotion: reduceMotion
                            ),
                            value: motion.isPlaying
                        )
                        .zIndex(1)
                }
            }

            if isCurrent {
                switch livePhotoReadiness {
                case .loading:
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .padding(16)
                        .protonGlass(in: Circle())
                        .allowsHitTesting(false)
                        .zIndex(2)
                case .failed:
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .padding(14)
                        .protonGlass(in: Circle())
                        .accessibilityLabel(L10n.string("viewer.playback_failed"))
                        .allowsHitTesting(false)
                        .zIndex(2)
                case .notApplicable, .ready:
                    EmptyView()
                }
            }
        }
        // Gentle scale under the still-to-motion crossfade.
        .scaleEffect(motion.isPlaying ? transition.liveMotionScale : 1)
        .animation(
            MobileViewerMotionPolicy.animation(
                .easeInOut(duration: transition.scaleDuration), reduceMotion: reduceMotion
            ),
            value: motion.isPlaying
        )
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            viewportSize = newSize
        }
        .task(
            id: ViewerImageLoadPolicy.LoadIdentity(
                uid: item.uid,
                isCurrent: isCurrent,
                maxPixelSize: displayLoadCap
            )
        ) {
            await load(maxPixelSize: displayLoadCap)
        }
        .task(id: MobileLivePhotoMotionTaskID(item: item, isCurrent: isCurrent)) {
            prepareOrStopMotion()
        }
        .onAppear {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] page appear uid=\(MobileViewerLog.short(item.uid), privacy: .public) current=\(isCurrent) kind=photo"
                )
            }
        }
        .onDisappear {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] page disappear uid=\(MobileViewerLog.short(item.uid), privacy: .public)")
            }
            motion.teardown()
        }
    }

    /// Releases motion for pages that leave the current position. The expensive preparation starts only from the
    /// native press/hover callback above.
    private func prepareOrStopMotion() {
        guard item.isLivePhoto, isCurrent else {
            motion.teardown()
            return
        }
    }

    private var livePhotoReadiness: LivePhotoCompositeReadiness {
        LivePhotoCompositeReadiness.resolve(
            requiresMotion: LivePhotoMotionPolicy.shouldPrepare(item: item, hasStreamer: streamer != nil),
            isFullResolutionStillReady: isFullResolutionStillReady,
            didFullResolutionStillFail: didFullResolutionStillFail,
            motionState: motion.loadState,
            isMotionRequested: motion.isPlayRequested || motion.loadState != .idle
        )
    }

    private var displayLoadCap: Int {
        max(
            displayedCap,
            ViewerImageLoadPolicy.displayMaxPixelSize(viewportPoints: viewportSize, scale: displayScale)
        )
    }

    private func load(maxPixelSize cap: Int) async {
        // Install the immediate grid thumbnail when no image is mounted.
        if image == nil, let thumb = imageStore.thumbnail(for: item.uid) {
            _ = installIfNotLowerQuality(thumb)
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] display uid=\(MobileViewerLog.short(item.uid), privacy: .public) tier=thumbnail")
            }
        }
        // Load a screen-bounded preview for the current page only.
        guard ViewerImageLoadPolicy.shouldLoadDisplay(distanceFromCurrent: isCurrent ? 0 : 1) else { return }
        if let display = await imageStore.displayImage(for: item.uid, maxPixelSize: cap), !Task.isCancelled,
            cap >= displayedCap, installIfNotLowerQuality(display, requestedCap: cap)
        {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] display uid=\(MobileViewerLog.short(item.uid), privacy: .public) tier=\(display.source, privacy: .public)"
                )
            }
        }
        await loadFullResolutionLivePhotoStill(maxPixelSize: cap)
        // The full original remains deferred until a settled zoom requests more pixels. Live Photos load the
        // bounded still needed for their composite readiness; paired motion remains demand-driven.
    }

    private func loadFullResolutionLivePhotoStill(maxPixelSize: Int) async {
        guard LivePhotoMotionPolicy.shouldPrepare(item: item, hasStreamer: streamer != nil),
            isCurrent
        else { return }
        didFullResolutionStillFail = false
        guard let sharp = await imageStore.originalImage(for: item.uid, maxPixelSize: maxPixelSize),
            !Task.isCancelled, isCurrent
        else {
            if !Task.isCancelled, isCurrent { didFullResolutionStillFail = true }
            return
        }
        _ = installIfNotLowerQuality(sharp, requestedCap: maxPixelSize)
        isFullResolutionStillReady = true
        if MobileViewerLog.isEnabled {
            MobileViewerLog.logger.notice(
                "[ViewerPerf] display uid=\(MobileViewerLog.short(item.uid), privacy: .public) tier=livePhotoOriginal"
            )
        }
    }

    /// After zoom settles beyond fit, decode the original at the size this zoom needs and swap it in.
    /// The swap is seamless: only `UIImageView.image` changes (same aspect ratio), and the scroll
    /// view's zoomScale/contentOffset are untouched, so nothing moves - the pixels just get sharper. The store
    /// serves the bytes from the E2EE originals cache (already fetched by the base tier) and its
    /// `decodedCap` cache gate turns repeat settles at the same zoom into instant hits.
    private func loadZoomedDecodeIfNeeded(zoom: CGFloat) {
        guard zoom > 1.01, isCurrent, viewportSize.width > 0, viewportSize.height > 0 else { return }
        let cap = ViewerImageLoadPolicy.zoomedMaxPixelSize(
            viewportPoints: viewportSize, scale: displayScale, zoom: zoom)
        zoomDecodeTask?.cancel()
        zoomDecodeTask = Task {
            guard let sharp = await imageStore.originalImage(for: item.uid, maxPixelSize: cap),
                !Task.isCancelled
            else { return }
            _ = installIfNotLowerQuality(sharp, requestedCap: cap)
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] display uid=\(MobileViewerLog.short(item.uid), privacy: .public) tier=zoomed cap=\(cap)"
                )
            }
        }
    }

    @discardableResult
    private func installIfNotLowerQuality(
        _ candidate: UIKitViewerImageStore.DisplayImage,
        requestedCap: Int? = nil
    ) -> Bool {
        guard
            ViewerImageLoadPolicy.shouldReplaceDisplayedImage(
                currentLongestPixelSide: displayedLongestPixelSide,
                candidateLongestPixelSide: candidate.longestPixelSide
            )
        else {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    """
                    [ViewerPerf] reject downgrade uid=\(MobileViewerLog.short(item.uid), privacy: .public) \
                    currentPx=\(displayedLongestPixelSide) candidatePx=\(candidate.longestPixelSide)
                    """
                )
            }
            return false
        }
        image = candidate.image
        displayedLongestPixelSide = max(displayedLongestPixelSide, candidate.longestPixelSide)
        if let requestedCap {
            displayedCap = max(displayedCap, requestedCap)
        }
        return true
    }
}

/// Native AVKit surface that keeps viewer gestures on UIKit's responder path. SwiftUI gestures attached outside
/// `VideoPlayer` do not reliably receive touches once AVKit's playback surface is active. AVKit documents its
/// content overlay for noninteractive decoration, so the recognizers live on the player controller's root view.
/// AVKit chrome is intentionally disabled because iOS exposes it only as one all-or-nothing surface; the app
/// owns the visible play and seek controls while AVKit retains playback, poster, and Picture in Picture behavior.
private struct MobileNativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let poster: UIImage?
    let reduceMotion: Bool
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize, CGFloat, Bool) -> Void
    let onPinchChanged: (CGFloat, UnitPoint) -> Void
    let onPinchEnded: (CGFloat, Bool) -> Void
    let onSingleTap: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.loadViewIfNeeded()
        context.coordinator.controller = controller
        context.coordinator.attachPoster(poster, to: controller)

        let gestureSurface = controller.view!

        let dismissPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDismissPan(_:))
        )
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.cancelsTouchesInView = false
        dismissPan.delegate = context.coordinator
        gestureSurface.addGestureRecognizer(dismissPan)
        context.coordinator.dismissPan = dismissPan

        let dismissPinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDismissPinch(_:))
        )
        dismissPinch.cancelsTouchesInView = false
        dismissPinch.delegate = context.coordinator
        gestureSurface.addGestureRecognizer(dismissPinch)
        context.coordinator.dismissPinch = dismissPinch

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.cancelsTouchesInView = false
        singleTap.delegate = context.coordinator
        gestureSurface.addGestureRecognizer(singleTap)
        context.coordinator.singleTap = singleTap

        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.controller = controller
        if controller.player !== player {
            controller.player = player
            context.coordinator.attachPoster(poster, to: controller)
        } else {
            context.coordinator.updatePoster(poster, in: controller)
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.teardownPoster()
        controller.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: MobileNativeVideoPlayer
        weak var controller: AVPlayerViewController?
        weak var dismissPan: UIPanGestureRecognizer?
        weak var dismissPinch: UIPinchGestureRecognizer?
        weak var singleTap: UITapGestureRecognizer?
        private weak var posterView: UIImageView?
        private var displayReadinessObservation: NSKeyValueObservation?

        init(parent: MobileNativeVideoPlayer) {
            self.parent = parent
        }

        func attachPoster(_ image: UIImage?, to controller: AVPlayerViewController) {
            teardownPoster()
            updatePoster(image, in: controller)
            displayReadinessObservation = controller.observe(
                \.isReadyForDisplay,
                options: [.initial, .new]
            ) { [weak self] _, change in
                guard change.newValue == true else { return }
                Task { @MainActor in self?.revealFirstFrame() }
            }
        }

        func updatePoster(_ image: UIImage?, in controller: AVPlayerViewController) {
            guard !controller.isReadyForDisplay, let image, let overlay = controller.contentOverlayView else {
                if image == nil { posterView?.removeFromSuperview() }
                return
            }
            let imageView: UIImageView
            if let posterView {
                imageView = posterView
            } else {
                imageView = UIImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.contentMode = .scaleAspectFit
                imageView.isUserInteractionEnabled = false
                overlay.addSubview(imageView)
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                    imageView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                    imageView.topAnchor.constraint(equalTo: overlay.topAnchor),
                    imageView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                ])
                posterView = imageView
            }
            imageView.image = image
            imageView.alpha = 1
            imageView.isHidden = false
        }

        func teardownPoster() {
            displayReadinessObservation?.invalidate()
            displayReadinessObservation = nil
            posterView?.removeFromSuperview()
        }

        private func revealFirstFrame() {
            guard let posterView, !posterView.isHidden else { return }
            guard !parent.reduceMotion else {
                posterView.alpha = 0
                finishPosterReveal()
                return
            }
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                posterView.alpha = 0
            } completion: { _ in
                Task { @MainActor in self.finishPosterReveal() }
            }
        }

        private func finishPosterReveal() {
            posterView?.isHidden = true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === dismissPan || gestureRecognizer === dismissPinch, isNativeVideoZoomed {
                return false
            }
            guard gestureRecognizer === dismissPan,
                let pan = gestureRecognizer as? UIPanGestureRecognizer,
                let view = pan.view
            else { return true }
            let velocity = pan.velocity(in: view)
            // Match the photo page: only a vertical pan belongs to dismiss. Returning false here leaves a
            // horizontal drag to the enclosing UIPageViewController's existing previous/next interaction.
            return abs(velocity.y) > abs(velocity.x)
        }

        /// AVKit owns video zoom and pan. Its public `videoBounds` reports the displayed media rect, so custom
        /// viewer-dismiss gestures must stand down once AVKit has enlarged it beyond the aspect-fit rect.
        private var isNativeVideoZoomed: Bool {
            guard let controller, let item = parent.player.currentItem else { return false }
            let presentationSize = item.presentationSize
            guard presentationSize.width > 0, presentationSize.height > 0,
                controller.view.bounds.width > 0, controller.view.bounds.height > 0
            else { return false }
            let fit = ViewerZoomGeometry.aspectFitRect(
                mediaSize: presentationSize,
                in: controller.view.bounds
            )
            return ViewerZoomGeometry.isZoomed(currentRect: controller.videoBounds, fitRect: fit)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            let value = CGSize(width: translation.x, height: translation.y)
            switch gesture.state {
            case .began, .changed:
                parent.onDragChanged(value)
            case .ended, .cancelled, .failed:
                parent.onDragEnded(value, gesture.velocity(in: view).y, gesture.state == .ended)
            default:
                break
            }
        }

        @objc func handleDismissPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let anchor = UnitPoint(
                x: view.bounds.width > 0 ? location.x / view.bounds.width : 0.5,
                y: view.bounds.height > 0 ? location.y / view.bounds.height : 0.5
            )
            switch gesture.state {
            case .began, .changed:
                parent.onPinchChanged(gesture.scale, anchor)
            case .ended, .cancelled, .failed:
                parent.onPinchEnded(gesture.scale, gesture.state == .ended)
            default:
                break
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            parent.onSingleTap()
        }
    }
}

private struct MobileVideoPlaybackControls: View {
    let currentTime: Double
    let duration: Double
    let isPlaying: Bool
    let onTogglePlayback: () -> Void
    let onSeekTo: (Double) -> Void

    @State private var scrubTime: Double?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var displayedTime: Double { scrubTime ?? currentTime }
    private var seekRange: ClosedRange<Double> { 0...max(duration, 0.1) }
    private var layoutProfile: ViewerChromeLayoutProfile {
        MobileViewerBottomLayout.profile(compactLandscape: verticalSizeClass == .compact)
    }

    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: 12) {
                playbackButton(
                    symbol: isPlaying ? "pause.fill" : "play.fill",
                    labelKey: isPlaying ? "viewer.video_pause_a11y" : "viewer.video_play_a11y"
                ) {
                    onTogglePlayback()
                }
                Slider(
                    value: Binding(
                        get: { min(max(displayedTime, seekRange.lowerBound), seekRange.upperBound) },
                        set: { scrubTime = $0 }
                    ), in: seekRange
                ) { editing in
                    if !editing, let scrubTime {
                        onSeekTo(scrubTime)
                        self.scrubTime = nil
                    }
                }
                .accessibilityLabel(Text("viewer.video_position_a11y"))
                .accessibilityValue(Text(Self.positionDescription(displayedTime, duration: duration)))
                .tint(Color.primary)
            }
            .padding(.horizontal, 16)
            .frame(height: layoutProfile.controlSide)
            .protonGlass(in: Capsule())
            .padding(.horizontal, MobileViewerBottomLayout.horizontalPadding)
            .padding(.bottom, layoutProfile.bottomChromeHeight + layoutProfile.rowSpacing)
            .safeAreaPadding(.bottom, layoutProfile.bottomPadding)
        }
    }

    private func playbackButton(
        symbol: String,
        labelKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(
                    width: layoutProfile.controlSide,
                    height: layoutProfile.controlSide
                )
        }
        .accessibilityLabel(Text(labelKey))
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let rounded = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }

    private static func positionDescription(_ seconds: Double, duration: Double) -> String {
        "\(timestamp(seconds)) / \(timestamp(duration))"
    }
}

/// Native video playback via AVKit over the shared `VideoStreamProvider` streaming asset. The grid thumbnail
/// remains in AVKit's noninteractive content overlay until `isReadyForDisplay` proves the first video frame can
/// replace it. The app owns the visible playback controls because hiding AVKit's AirPlay and volume buttons also
/// hides its entire control surface. Paging and dismiss continue through the same shared policies as photos.
private struct MobileVideoPage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let showsChrome: Bool
    let libraryModel: MobileLibraryModel
    let onToggleChrome: () -> Void
    let onCloseRequested: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVPlayer?
    /// The streaming asset is the only strong owner of the range resource-loader, which AVFoundation holds
    /// weakly - it must live as long as the player, or every protonvideo:// range request goes unserved.
    @State private var streamingAsset: StreamingVideoAsset?
    @State private var failed = false
    @State private var poster: UIImage?
    @State private var pinch = ViewerPinchState()
    @State private var drag = ViewerDragState()
    @State private var viewportHeight: CGFloat = 0
    @State private var playbackTime: Double = 0
    @State private var playbackDuration: Double = 0
    @State private var playbackIsPlaying = false
    /// `timeControlStatus == .waitingToPlayAtSpecifiedRate` means playback still intends to continue after
    /// buffering. Keep that intent separate from the visible "currently progressing" state.
    @State private var playbackIntendsToPlay = false
    @State private var playbackIsBuffering = false

    var body: some View {
        ZStack {
            if let player {
                MobileNativeVideoPlayer(
                    player: player,
                    poster: poster,
                    reduceMotion: reduceMotion,
                    onDragChanged: handleDragChanged,
                    onDragEnded: handleDragEnded,
                    onPinchChanged: handlePinchChanged,
                    onPinchEnded: handlePinchEnded,
                    onSingleTap: onToggleChrome
                )
                .ignoresSafeArea()
                .onAppear {
                    if isCurrent {
                        playbackIntendsToPlay = true
                        player.play()
                    }
                }

                if showsChrome {
                    MobileVideoPlaybackControls(
                        currentTime: playbackTime,
                        duration: playbackDuration,
                        isPlaying: playbackIsPlaying || playbackIsBuffering,
                        onTogglePlayback: togglePlayback,
                        onSeekTo: seek(to:)
                    )
                    .transition(.opacity)
                }
            } else if failed {
                ContentUnavailableView(
                    L10n.string("viewer.playback_failed"),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.white)
            } else {
                // AVKit is not mounted yet, so this is the only loading indicator. Once `player` is assigned,
                // the entire preparation layer leaves and can no longer cover native buffering or controls.
                if let poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFit()
                        .allowsHitTesting(false)
                }
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .scaleEffect(pinch.displayScale * drag.scale, anchor: drag.isActive ? .center : pinch.anchor)
        .offset(drag.offset)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            viewportHeight = $0
        }
        .task(id: LoadToken(uid: item.uid, current: isCurrent)) { await prepare() }
        .task(id: player.map(ObjectIdentifier.init)) {
            guard let player else { return }
            await observePlayback(player)
        }
        .onChange(of: isCurrent) { _, current in
            if current {
                playbackIntendsToPlay = true
                player?.play()
            } else {
                playbackIntendsToPlay = false
                player?.pause()
            }
        }
        .onAppear {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] page appear uid=\(MobileViewerLog.short(item.uid), privacy: .public) current=\(isCurrent) kind=video"
                )
            }
        }
        .onDisappear {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] page disappear uid=\(MobileViewerLog.short(item.uid), privacy: .public)")
            }
            teardown()
        }
    }

    private struct LoadToken: Equatable {
        let uid: PhotoUID
        let current: Bool
    }

    @MainActor
    private func observePlayback(_ observedPlayer: AVPlayer) async {
        while !Task.isCancelled, player === observedPlayer {
            let time = observedPlayer.currentTime().seconds
            if time.isFinite { playbackTime = max(0, time) }
            let duration = observedPlayer.currentItem?.duration.seconds ?? 0
            if duration.isFinite, duration > 0 { playbackDuration = duration }
            playbackIsPlaying = MobileVideoPlaybackIntent.isActivelyPlaying(observedPlayer.timeControlStatus)
            playbackIsBuffering = MobileVideoPlaybackIntent.isBuffering(observedPlayer.timeControlStatus)
            if MobileVideoPlaybackIntent.reachedEnd(current: playbackTime, duration: playbackDuration),
                observedPlayer.timeControlStatus == .paused
            {
                playbackIntendsToPlay = false
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        let willPlay = !playbackIntendsToPlay
        playbackIntendsToPlay = willPlay
        if willPlay {
            if MobileVideoPlaybackIntent.reachedEnd(current: playbackTime, duration: playbackDuration) {
                playbackTime = 0
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
        } else {
            player.pause()
        }
        playbackIsPlaying = willPlay && player.timeControlStatus == .playing
        playbackIsBuffering = willPlay && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let upper = playbackDuration > 0 ? playbackDuration : max(0, seconds)
        let target = min(max(0, seconds), upper)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playbackTime = target
    }

    private func handleDragChanged(_ translation: CGSize) {
        if !drag.isActive {
            guard ViewerDragDismissPolicy.engages(translation: translation, isZoomedIn: false) else { return }
            drag.isActive = true
        }
        let progress = ViewerDragDismissPolicy.progress(
            translationY: translation.height, viewportHeight: viewportHeight)
        drag.offset = translation
        drag.scale = ViewerDragDismissPolicy.displayScale(progress: progress)
    }

    private func handleDragEnded(_ translation: CGSize, velocityY: CGFloat, completed: Bool) {
        guard drag.isActive else { return }
        drag.isActive = false
        if completed,
            ViewerDragDismissPolicy.shouldDismiss(
                translationY: translation.height,
                velocityY: velocityY,
                viewportHeight: viewportHeight
            )
        {
            onCloseRequested()
        } else {
            withAnimation(
                MobileViewerMotionPolicy.animation(
                    .spring(
                        duration: ViewerDragDismissPolicy.springBackDuration,
                        bounce: 1 - Double(ViewerDragDismissPolicy.springBackDamping)
                    ),
                    reduceMotion: reduceMotion
                )
            ) {
                drag.offset = .zero
                drag.scale = 1
            }
        }
    }

    private func handlePinchChanged(_ gestureScale: CGFloat, anchor: UnitPoint) {
        if !pinch.isActive {
            guard ViewerPinchDismissPolicy.engages(gestureScale: gestureScale, isZoomedIn: false) else { return }
            pinch.isActive = true
            pinch.anchor = anchor
        }
        pinch.displayScale = ViewerPinchDismissPolicy.displayScale(gestureScale: gestureScale)
    }

    private func handlePinchEnded(_ gestureScale: CGFloat, completed: Bool) {
        guard pinch.isActive else { return }
        pinch.isActive = false
        if completed, ViewerPinchDismissPolicy.shouldDismiss(releaseScale: gestureScale) {
            onCloseRequested()
        } else {
            withAnimation(
                MobileViewerMotionPolicy.animation(
                    .spring(
                        duration: ViewerPinchDismissPolicy.springBackDuration,
                        bounce: 1 - Double(ViewerPinchDismissPolicy.springBackDamping)
                    ),
                    reduceMotion: reduceMotion
                )
            ) {
                pinch.displayScale = 1
            }
        }
    }

    private func prepare() async {
        // Reuse the grid thumbnail as the poster. Only the current page creates a player or network loader.
        if poster == nil {
            poster = libraryModel.thumbnailFeed?.memoryImage(for: item.uid)
        }
        guard isCurrent, player == nil, let backend = libraryModel.backend else { return }
        failed = false
        if MobileViewerLog.isEnabled {
            MobileViewerLog.logger.notice(
                "[ViewerPerf] video prepare start uid=\(MobileViewerLog.short(item.uid), privacy: .public)")
        }
        do {
            let streaming = try await backend.makeStreamingAsset(for: item.uid)
            guard !Task.isCancelled else { return }  // A cancelled page must not attach a player.
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: streaming.asset))
            streamingAsset = streaming  // retain the resource loader for the player's lifetime
            player = newPlayer
            if isCurrent {
                playbackIntendsToPlay = true
                newPlayer.play()
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, isCurrent else { return }
            failed = true
        }
    }

    private func teardown() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        streamingAsset = nil
        playbackTime = 0
        playbackDuration = 0
        playbackIsPlaying = false
        playbackIntendsToPlay = false
        playbackIsBuffering = false
    }
}

/// Live pinch-to-close state for the SwiftUI (video) page.
private struct ViewerPinchState {
    var isActive = false
    var displayScale: CGFloat = 1
    var anchor: UnitPoint = .center
}

/// Live one-finger drag-to-close state for the SwiftUI (video) page.
private struct ViewerDragState {
    var isActive = false
    var offset: CGSize = .zero
    var scale: CGFloat = 1
}

/// UIScrollView-backed zoomable image: pinch + double-tap to zoom, single-tap toggles chrome. At minimum zoom
/// the scroll view does not pan, so the enclosing page TabView keeps its swipe - and a pinch-IN at minimum
/// zoom hands the image to the shared pinch-to-close interaction (`ViewerPinchDismissPolicy`): it sticks to
/// the fingers, springs back below the threshold, closes past it.
private final class MobileViewerZoomScrollView: UIScrollView {
    var onViewportWillChange: (() -> Void)?
    var onLayout: (() -> Void)?

    override var frame: CGRect {
        willSet {
            if newValue.size != frame.size { onViewportWillChange?() }
        }
    }

    override var bounds: CGRect {
        willSet {
            if newValue.size != bounds.size { onViewportWillChange?() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

// Internal so the production UIKit adapter can keep its layout and zoom lifecycle behind the SwiftUI call site.
struct MobileZoomableImage: UIViewRepresentable {
    let image: UIImage
    let reduceMotion: Bool
    let onSingleTap: () -> Void
    let onCloseRequested: () -> Void
    /// Live Photo long-press: press-and-hold plays the paired motion clip, release stops it. Nil for a non-Live
    /// photo, in which case no long-press recognizer is installed.
    var onMotionStart: (() -> Void)? = nil
    var onMotionStop: (() -> Void)? = nil
    /// Reports the displayed photo rect (the aspect-fit image area, zoom- and pan-transformed) in the page's
    /// coordinate space whenever layout/zoom/pan changes it. Drives the photo-anchored Live badge and the
    /// motion overlay's geometry, so both stay glued to the photo instead of the viewer.
    var onPhotoFrameChanged: ((CGRect) -> Void)? = nil
    /// Fired when a zoom gesture or animation settles, with the final zoom scale. The page uses it to swap in a
    /// sharper decode sized for that zoom (never during the gesture, so the interaction stays fluid).
    var onZoomSettled: ((CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = MobileViewerZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = .zero
        imageView.autoresizingMask = []
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        scrollView.onViewportWillChange = { [weak coordinator = context.coordinator] in
            coordinator?.captureVisibleAnchorBeforeViewportChange()
        }
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.updateZoomContentGeometry()
        }

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        // Pinch-to-close rides alongside the scroll view's own zoom pinch and takes over only when the
        // image is unzoomed and the fingers move inward (shared policy). It never blocks zooming.
        let dismissPinch = UIPinchGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDismissPinch(_:)))
        dismissPinch.delegate = context.coordinator
        scrollView.addGestureRecognizer(dismissPinch)

        // One-finger drag-to-close begins only on a clearly vertical drag while unzoomed (shared policy +
        // `gestureRecognizerShouldBegin`), so a horizontal drag falls through to the page TabView's swipe and a
        // zoomed image still pans normally. It tracks the finger and closes / springs back on release.
        let dismissPan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDismissPan(_:)))
        dismissPan.delegate = context.coordinator
        dismissPan.maximumNumberOfTouches = 1
        scrollView.addGestureRecognizer(dismissPan)
        context.coordinator.dismissPan = dismissPan

        // Live Photo long-press: a stationary press-and-hold plays the paired motion clip; release/cancel stops
        // it. Installed only for Live Photos (callbacks non-nil). Rides alongside the other recognizers, so any
        // drag cancels it back to the still and pans/zooms as usual.
        if onMotionStart != nil {
            let longPress = UILongPressGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
            longPress.minimumPressDuration = 0.3
            longPress.delegate = context.coordinator
            scrollView.addGestureRecognizer(longPress)
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onCloseRequested = onCloseRequested
        context.coordinator.onMotionStart = onMotionStart
        context.coordinator.onMotionStop = onMotionStop
        context.coordinator.onPhotoFrameChanged = onPhotoFrameChanged
        context.coordinator.onZoomSettled = onZoomSettled
        context.coordinator.reduceMotion = reduceMotion
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            // Geometry must be current before SwiftUI presents the replacement image. Reporting the new
            // frame stays deferred because the callback writes page @State during this representable update.
            context.coordinator.updateZoomContentGeometry(reportChanges: false)
        }
        // Initial/refresh report, async: we're inside a SwiftUI view update, and the callback writes @State.
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.reportPhotoFrame()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleTap: onSingleTap,
            onCloseRequested: onCloseRequested,
            onMotionStart: onMotionStart,
            onMotionStop: onMotionStop,
            reduceMotion: reduceMotion
        )
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        var onSingleTap: () -> Void
        var onCloseRequested: () -> Void
        var onMotionStart: (() -> Void)?
        var onMotionStop: (() -> Void)?
        var onPhotoFrameChanged: ((CGRect) -> Void)?
        var onZoomSettled: ((CGFloat) -> Void)?
        var reduceMotion: Bool
        /// Last reported photo rect - reports are de-duplicated so a steady frame never spams @State updates.
        private var lastReportedPhotoFrame: CGRect = .null

        private var dismissPinchActive = false
        private var pinchStartCentroid: CGPoint = .zero
        weak var dismissPan: UIPanGestureRecognizer?
        private var dismissPanActive = false
        private var motionActive = false
        private var updatingZoomGeometry = false
        private var lastZoomViewport: CGSize = .zero
        private var lastZoomMediaSize: CGSize = .zero
        private var pendingVisibleAnchor: CGPoint?

        init(
            onSingleTap: @escaping () -> Void,
            onCloseRequested: @escaping () -> Void,
            onMotionStart: (() -> Void)?,
            onMotionStop: (() -> Void)?,
            reduceMotion: Bool
        ) {
            self.onSingleTap = onSingleTap
            self.onCloseRequested = onCloseRequested
            self.onMotionStart = onMotionStart
            self.onMotionStop = onMotionStop
            self.reduceMotion = reduceMotion
        }

        /// Live Photo playback: begin on the long-press threshold, end on release/cancel. The `motionActive`
        /// guard means a stray terminal state without a matching `.began` can never fire a spurious stop.
        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                motionActive = true
                onMotionStart?()
            case .ended, .cancelled, .failed:
                if motionActive {
                    motionActive = false
                    onMotionStop?()
                }
            default:
                break
            }
        }

        /// Keeps UIKit's zoom document equal to the actual fitted media, rather than the whole viewport.
        /// This leaves native rubber-band behavior intact while making its settled edges the photo edges.
        func captureVisibleAnchorBeforeViewportChange() {
            guard !updatingZoomGeometry, pendingVisibleAnchor == nil,
                let scrollView, lastZoomViewport != .zero,
                scrollView.zoomScale > scrollView.minimumZoomScale + 0.01,
                scrollView.contentSize != .zero
            else { return }
            let settledOrigin = ViewerZoomGeometry.settledOrigin(
                proposedOrigin: scrollView.contentOffset,
                contentSize: scrollView.contentSize,
                viewportSize: lastZoomViewport
            )
            pendingVisibleAnchor = ViewerZoomGeometry.normalizedVisibleAnchor(
                contentOrigin: settledOrigin,
                contentSize: scrollView.contentSize,
                viewportSize: lastZoomViewport
            )
        }

        func updateZoomContentGeometry(reportChanges: Bool = true) {
            guard !updatingZoomGeometry, let scrollView, let imageView, let image = imageView.image else { return }
            let viewport = scrollView.bounds.size
            guard viewport.width > 0, viewport.height > 0 else { return }
            if viewport == lastZoomViewport, image.size == lastZoomMediaSize {
                if reportChanges { reportPhotoFrame() }
                return
            }
            let fitSize = ViewerZoomGeometry.aspectFitSize(mediaSize: image.size, viewportSize: viewport)
            guard fitSize != .zero else { return }

            updatingZoomGeometry = true
            let zoom = max(scrollView.minimumZoomScale, scrollView.zoomScale)
            let oldContentSize = scrollView.contentSize
            let oldOffset = scrollView.contentOffset
            let oldViewport = lastZoomViewport == .zero ? viewport : lastZoomViewport
            let settledOldOrigin = ViewerZoomGeometry.settledOrigin(
                proposedOrigin: oldOffset,
                contentSize: oldContentSize,
                viewportSize: oldViewport
            )
            let visibleAnchor =
                pendingVisibleAnchor
                ?? ViewerZoomGeometry.normalizedVisibleAnchor(
                    contentOrigin: settledOldOrigin,
                    contentSize: oldContentSize,
                    viewportSize: oldViewport
                )
            pendingVisibleAnchor = nil
            // Reset the native zoom transform before changing bounds and center. Restoring it below makes
            // UIScrollView recompute its scaled content size for the new fitted media geometry.
            if zoom > scrollView.minimumZoomScale + 0.001 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
            }
            // UIKit applies the zoom as a transform. `bounds` and `center` remain valid while transformed;
            // changing `frame` during rotation or a sharp-image upgrade is undefined.
            imageView.bounds = CGRect(origin: .zero, size: fitSize)
            imageView.center = CGPoint(x: fitSize.width / 2, y: fitSize.height / 2)
            scrollView.contentSize = fitSize
            scrollView.contentInset = .zero
            // iOS 26 is the package minimum. Center the smaller axis without adding pannable letterbox.
            scrollView.contentAlignmentPoint = CGPoint(x: 0.5, y: 0.5)
            if abs(zoom - scrollView.zoomScale) > 0.001 {
                scrollView.setZoomScale(zoom, animated: false)
            }
            if zoom > scrollView.minimumZoomScale + 0.01, oldContentSize != .zero {
                let scaledContentSize = scrollView.contentSize
                let settled = ViewerZoomGeometry.rebasedOrigin(
                    anchor: visibleAnchor,
                    contentSize: scaledContentSize,
                    viewportSize: viewport
                )
                scrollView.contentOffset = settled
            }
            lastZoomViewport = viewport
            lastZoomMediaSize = image.size
            updatingZoomGeometry = false
            if reportChanges { reportPhotoFrame() }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        /// The displayed photo rect: the aspect-FIT area of the image inside the (zoom-scaled) image view,
        /// converted to the scroll view's superview space - the same space the page's SwiftUI overlays use.
        func displayedPhotoFrame() -> CGRect? {
            guard let scrollView, let imageView, let img = imageView.image,
                img.size.width > 0, img.size.height > 0
            else { return nil }
            return imageView.convert(imageView.bounds, to: scrollView.superview)
        }

        func reportPhotoFrame() {
            guard let frame = displayedPhotoFrame() else { return }
            // Sub-point changes are invisible; skip them so pan/zoom doesn't flood SwiftUI with state writes.
            if abs(frame.minX - lastReportedPhotoFrame.minX) < 0.5,
                abs(frame.minY - lastReportedPhotoFrame.minY) < 0.5,
                abs(frame.width - lastReportedPhotoFrame.width) < 0.5,
                abs(frame.height - lastReportedPhotoFrame.height) < 0.5
            {
                return
            }
            lastReportedPhotoFrame = frame
            onPhotoFrameChanged?(frame)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if !updatingZoomGeometry { reportPhotoFrame() }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if !updatingZoomGeometry { reportPhotoFrame() }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            reportPhotoFrame()
            onZoomSettled?(scale)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// Gate the dismiss pan so it begins only on a clearly vertical drag while the image is unzoomed - a
        /// horizontal drag then falls through to the page TabView's paging swipe, and a zoomed image keeps its
        /// scroll-view pan. Every other recognizer begins normally.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === dismissPan, let scrollView else { return true }
            let isZoomedIn = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            guard !isZoomedIn else { return false }
            let v = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: scrollView) ?? .zero
            return abs(v.y) > abs(v.x)
        }

        @objc func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView, let container = scrollView.superview else { return }
            let translation = gesture.translation(in: container)
            switch gesture.state {
            case .began, .changed:
                if !dismissPanActive {
                    let isZoomedIn = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
                    guard
                        ViewerDragDismissPolicy.engages(
                            translation: CGSize(width: translation.x, height: translation.y), isZoomedIn: isZoomedIn)
                    else { return }
                    dismissPanActive = true
                }
                let progress = ViewerDragDismissPolicy.progress(
                    translationY: translation.y, viewportHeight: container.bounds.height)
                let scale = ViewerDragDismissPolicy.displayScale(progress: progress)
                scrollView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
                    .scaledBy(x: scale, y: scale)
            case .ended, .cancelled, .failed:
                guard dismissPanActive else { return }
                dismissPanActive = false
                let velocity = gesture.velocity(in: container)
                if gesture.state == .ended,
                    ViewerDragDismissPolicy.shouldDismiss(
                        translationY: translation.y, velocityY: velocity.y, viewportHeight: container.bounds.height)
                {
                    onCloseRequested()
                } else {
                    guard !reduceMotion else {
                        scrollView.transform = .identity
                        return
                    }
                    UIView.animate(
                        withDuration: ViewerDragDismissPolicy.springBackDuration,
                        delay: 0,
                        usingSpringWithDamping: ViewerDragDismissPolicy.springBackDamping,
                        initialSpringVelocity: 0,
                        options: [.allowUserInteraction, .beginFromCurrentState]
                    ) {
                        scrollView.transform = .identity
                    }
                }
            default:
                break
            }
        }

        @objc func handleSingleTap() { onSingleTap() }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: !reduceMotion)
            } else {
                let point = gesture.location(in: imageView)
                let side = scrollView.bounds.size
                let zoomRect = CGRect(
                    x: point.x - side.width / 6, y: point.y - side.height / 6,
                    width: side.width / 3, height: side.height / 3)
                scrollView.zoom(to: zoomRect, animated: !reduceMotion)
            }
            // Programmatic zooms don't reliably deliver `scrollViewDidEndZooming` - settle explicitly once the
            // zoom animation is over, so a double-tap zoom also gets its sharper decode.
            DispatchQueue.main.asyncAfter(
                deadline: .now() + MobileViewerMotionPolicy.duration(0.4, reduceMotion: reduceMotion)
            ) { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.reportPhotoFrame()
                self.onZoomSettled?(scrollView.zoomScale)
            }
        }

        @objc func handleDismissPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let scrollView, let container = scrollView.superview else { return }
            switch gesture.state {
            case .began, .changed:
                if !dismissPinchActive {
                    let isZoomedIn = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
                    guard ViewerPinchDismissPolicy.engages(gestureScale: gesture.scale, isZoomedIn: isZoomedIn)
                    else { return }
                    dismissPinchActive = true
                    pinchStartCentroid = gesture.location(in: container)
                    // Take the gesture over from the scroll view's bounce-zoom for its remainder.
                    scrollView.pinchGestureRecognizer?.isEnabled = false
                    scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
                }
                let scale = ViewerPinchDismissPolicy.displayScale(gestureScale: gesture.scale)
                let centroid = gesture.location(in: container)
                let center = scrollView.center
                // Keep the image point that was under the fingers under the fingers: scale about the view
                // center, then translate so the engaged centroid tracks the live centroid.
                let tx = centroid.x - center.x - scale * (pinchStartCentroid.x - center.x)
                let ty = centroid.y - center.y - scale * (pinchStartCentroid.y - center.y)
                scrollView.transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
            case .ended, .cancelled, .failed:
                guard dismissPinchActive else { return }
                dismissPinchActive = false
                scrollView.pinchGestureRecognizer?.isEnabled = true
                if gesture.state == .ended, ViewerPinchDismissPolicy.shouldDismiss(releaseScale: gesture.scale) {
                    onCloseRequested()
                } else {
                    guard !reduceMotion else {
                        scrollView.transform = .identity
                        return
                    }
                    UIView.animate(
                        withDuration: ViewerPinchDismissPolicy.springBackDuration,
                        delay: 0,
                        usingSpringWithDamping: ViewerPinchDismissPolicy.springBackDamping,
                        initialSpringVelocity: 0,
                        options: [.allowUserInteraction, .beginFromCurrentState]
                    ) {
                        scrollView.transform = .identity
                    }
                }
            default:
                break
            }
        }
    }
}

/// Hosts the Live Photo motion clip's `AVPlayerLayer` over the still - aspect-fit, transparent, non-interactive
/// (the still underneath keeps the zoom/tap gestures). Mirrors the macOS `MotionPlayerLayerView`.
private struct MobileMotionPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// The small "LIVE" affordance shown on a Live Photo page - signals the press-and-hold-to-play interaction.
private struct MobileLiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "livephoto")
            Text(L10n.string("viewer.live_badge"))
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .protonGlass(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("viewer.live_photo_a11y"))
    }
}
