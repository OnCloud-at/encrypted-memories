import DesignSystemCore
import Foundation
import LibraryRuntimeAppleAdapter
import MLSearchCore
import MLSearchFeature
import Metal
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonCoreCryptoPatchedGoImplementation
import SwiftUI
import TimelineCore
import TimelineUIKitAdapter
import UIKit
import UploadCore
import os

@main
struct EncryptedMemoriesMobileApp: App {
    private let metal3Supported: Bool

    init() {
        let metal3Supported = MobileMetal3Runtime.isSupported()
        self.metal3Supported = metal3Supported
        MobileBuildProvenanceLog.noteCurrentBuild()
        guard metal3Supported else { return }

        AppleLibraryRuntimeAdapter.shared.install()
        MobileMetricKitCollector.shared.install()
        PhotoBackupBackgroundCoordinator.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            if metal3Supported {
                MobileSupportedAppRoot()
            } else {
                ZStack {
                    ProtonColor.backgroundNorm.ignoresSafeArea()
                    MobileUnsupportedDeviceView()
                }
            }
        }
    }

    /// One shared reference for the BG task handler - the handler outlives any scene, so it must
    /// not capture SwiftUI-owned state. Set by `MobileLibraryModel` when the account is ready.
    @MainActor
    static func currentPhotoBackup() -> PhotoLibraryBackupController? {
        PhotoLibraryBackupSharedRef.shared.controller
    }
}

/// Owns account and library state only after the physical device passes the Metal 3 capability gate.
private struct MobileSupportedAppRoot: View {
    @StateObject private var sessionModel: MobileSessionModel
    /// `@State` (not `@StateObject`) because `MobileLibraryModel` is `@Observable`: SwiftUI then tracks its
    /// properties individually, so non-grid tabs don't re-render on a timeline snapshot change.
    @State private var libraryModel: MobileLibraryModel
    @State private var confettiMotion = MobileConfettiMotion.shared
    @State private var tipJarCelebration = TipJarCelebrationCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _sessionModel = StateObject(wrappedValue: MobileSessionModel())
        _libraryModel = State(initialValue: MobileLibraryModel())
    }

    var body: some View {
        MobileRootView()
            .environmentObject(sessionModel)
            .environment(libraryModel)
            .overlay {
                TipJarCelebrationOverlay(horizontalBias: confettiMotion.horizontalBias)
            }
            .task {
                libraryModel.configure(session: sessionModel.session, store: sessionModel.sessionStore)
            }
            .task {
                await TipJarTransactionProcessor.shared.start()
            }
            .onChange(of: sessionModel.session) { _, session in
                libraryModel.configure(session: session, store: sessionModel.sessionStore)
            }
            .onChange(of: tipJarCelebration.activeCelebration?.id) { _, celebrationID in
                if celebrationID == nil || reduceMotion {
                    confettiMotion.stop()
                } else {
                    confettiMotion.start()
                }
            }
            .onChange(of: reduceMotion) { _, isReduced in
                if isReduced {
                    confettiMotion.stop()
                } else if tipJarCelebration.activeCelebration != nil {
                    confettiMotion.start()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                let opportunity: LibraryExecutionOpportunity
                switch phase {
                case .active: opportunity = .foregroundActive
                case .inactive: opportunity = .foregroundInactive
                case .background: opportunity = .backgroundPermitted
                @unknown default: opportunity = .foregroundInactive
                }
                AppleLibraryRuntimeAdapter.shared.setExecutionOpportunity(opportunity)
                if phase == .background {
                    PhotoBackupBackgroundCoordinator.shared.applicationDidEnterBackground(
                        controller: EncryptedMemoriesMobileApp.currentPhotoBackup()
                    )
                } else if phase == .active {
                    PhotoBackupBackgroundCoordinator.shared.applicationDidBecomeActive(
                        controller: EncryptedMemoriesMobileApp.currentPhotoBackup()
                    )
                    // Foregrounding reopens the background-indexing gate promptly.
                    libraryModel.smartSearch?.noteConditionsChanged()
                    Task { await libraryModel.refreshAccountInfo() }
                }
                libraryModel.setApplicationActive(phase == .active)
            }
            .onDisappear {
                confettiMotion.stop()
            }
            .onChange(of: libraryModel.photoBackup?.uploadedLibraryMutationRevision) { _, _ in
                libraryModel.refreshAfterLocalUpload()
            }
            .onChange(of: libraryModel.facade?.uploadCoordinator.completedUploadRevision) { _, _ in
                libraryModel.refreshAfterLocalUpload()
            }
            .onChange(of: libraryModel.isSigningOut) { _, signingOut in
                if !signingOut {
                    sessionModel.completeSignOutPresentation()
                }
            }
    }
}

private enum MobileBuildProvenanceLog {
    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "BuildProvenance")

    static func noteCurrentBuild(bundle: Bundle = .main) {
        #if DEBUG
            let commit = bundle.object(forInfoDictionaryKey: "EncryptedMemoriesBuildCommit") as? String ?? "unknown"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            logger.notice("[BuildProvenance] commit=\(commit, privacy: .public) build=\(build, privacy: .public)")
        #endif
    }
}

/// Top-level mobile routes. They are shared by the compact iPhone tab shell and the regular-width iPad sidebar
/// shell, so navigation chrome can adapt without duplicating feature screens or Core logic.
enum MobileTab: CaseIterable, Hashable, Identifiable {
    case photos, collections, map, search

    var id: Self { self }

    var name: String {
        switch self {
        case .photos: "photos"
        case .collections: "collections"
        case .map: "map"
        case .search: "search"
        }
    }

    var title: String {
        switch self {
        case .photos: L10n.string("library.title")
        case .collections: String(localized: "tab.collections")
        case .map: String(localized: "tab.map")
        case .search: String(localized: "tab.search")
        }
    }

    var systemImage: String {
        switch self {
        case .photos: "photo.on.rectangle.angled"
        case .collections: "square.stack"
        case .map: "map"
        case .search: "magnifyingglass"
        }
    }
}

/// Low-noise `[UIHitch]` tab-transition log (state-change only), same subsystem/category as the grid host's
/// `[UIHitch]` lines so one `log stream` filtered to that category shows tab changes AND grid frame stalls.
enum MobileTabActivityLog {
    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "UIHitch")
    static func note(tab: MobileTab) {
        logger.notice("[UIHitch] event=tab tab=\(tab.name, privacy: .public)")
    }
}

/// Selects the top-level presentation: unsupported GPU shows a capability message, signed-out users see login,
/// and signed-in users enter the app.
enum MobileRootPresentation: Equatable {
    case unsupportedDevice
    case restoringSession
    case signedOut
    case signedIn

    static func resolve(
        metalSupported: Bool,
        isCheckingSession: Bool,
        hasSession: Bool
    ) -> Self {
        guard metalSupported else { return .unsupportedDevice }
        if isCheckingSession { return .restoringSession }
        return hasSession ? .signedIn : .signedOut
    }
}

private struct MobileRootView: View {
    @EnvironmentObject private var sessionModel: MobileSessionModel
    @Environment(MobileLibraryModel.self) private var libraryModel

    var body: some View {
        ZStack {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            switch MobileRootPresentation.resolve(
                // `EncryptedMemoriesMobileApp` gates this root before it is created.
                metalSupported: true,
                isCheckingSession: sessionModel.isCheckingSession,
                hasSession: sessionModel.session != nil
            ) {
            case .unsupportedDevice:
                MobileUnsupportedDeviceView()
            case .restoringSession:
                MobileLibraryLoadingView(
                    isPresented: true,
                    accessibilityLabel: L10n.string("auth.checking_session"),
                    activityMessage: "\(L10n.string("library.title_activity")) …",
                    activityState: .working
                )
            case .signedOut:
                MobileLoginView()
            case .signedIn:
                MobileMainTabView()
                    .id(libraryModel.scopePresentationRevision)
            }
        }
        .overlay {
            MobileLibraryLoadingView(
                isPresented: sessionModel.isSigningOut || libraryModel.isSigningOut,
                accessibilityLabel: L10n.string("auth.signing_out"),
                activityMessage: L10n.string("auth.signing_out"),
                activityState: .working
            )
        }
    }
}

/// Shared tab hierarchy; the system adapts its presentation for iPhone and iPad.
private struct MobileMainTabView: View {
    @Environment(MobileLibraryModel.self) private var libraryModel
    @State private var selection: MobileTab = .photos
    @State private var networkMonitor = NetworkMonitor.shared
    @Namespace private var libraryActivityTransition
    /// Viewer presentation lives above the adaptive shell so a live iPad resize cannot dismiss open media.
    @State private var viewerRouter = MobileViewerRouter()

    /// Covers navigation chrome until the initial library surface is ready.
    private var showsLibraryLoadingCover: Bool {
        guard libraryModel.loadState.isLoading else { return false }
        return networkMonitor.isOnline || !libraryModel.items.isEmpty
    }

    private var loadingActivityMessage: String {
        networkMonitor.isOnline
            ? "\(L10n.string("library.title_activity")) …"
            : L10n.string("library.title_offline")
    }

    private var loadingActivityState: LibraryActivityBannerState {
        networkMonitor.isOnline ? .working : .offline
    }

    var body: some View {
        MobileAdaptiveTabShell(selection: $selection)
            .environment(viewerRouter)
            .overlay {
                MobileLibraryLoadingView(
                    isPresented: showsLibraryLoadingCover,
                    activityMessage: loadingActivityMessage,
                    activityState: loadingActivityState
                )
            }
            .libraryActivityTransition(
                namespace: libraryActivityTransition,
                loadingCoverPresented: showsLibraryLoadingCover
            )
            .fullScreenCover(
                item: Binding(
                    get: { viewerRouter.presentation },
                    set: { viewerRouter.presentation = $0 }
                )
            ) { presentation in
                MobilePhotoViewer(
                    items: presentation.items,
                    startIndex: presentation.index,
                    context: presentation.context,
                    libraryModel: libraryModel,
                    viewerRouter: viewerRouter
                )
            }
    }
}

private struct MobileAdaptiveTabShell: View {
    @Binding var selection: MobileTab
    /// Bumped when the already-active Photos tab is retapped, so the timeline scrolls to the newest photos.
    @State private var photosScrollSignal = 0
    @State private var searchText = ""
    @State private var searchScope: MLSearchScope = .all

    /// A custom selection binding makes an already-active Photos-tab retap observable. The route and grid
    /// remain mounted; only the newest-photo scroll signal changes.
    private var tabSelection: Binding<MobileTab> {
        Binding {
            selection
        } set: { newValue in
            if newValue == .photos, selection == .photos {
                photosScrollSignal &+= 1
            }
            selection = newValue
        }
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab(MobileTab.photos.title, systemImage: MobileTab.photos.systemImage, value: MobileTab.photos) {
                MobileTimelineScreen(
                    surface: .library,
                    isActive: selection == .photos,
                    scrollToLatestSignal: photosScrollSignal
                )
            }
            Tab(
                MobileTab.collections.title, systemImage: MobileTab.collections.systemImage,
                value: MobileTab.collections
            ) {
                MobileCollectionsScreen()
            }
            Tab(MobileTab.map.title, systemImage: MobileTab.map.systemImage, value: MobileTab.map) {
                MobileMapScreen()
            }
            Tab(value: MobileTab.search, role: .search) {
                MobileSearchTabScreen(
                    isActive: selection == .search,
                    searchText: $searchText,
                    searchScope: $searchScope
                )
            }
        }
        .tabViewSearchActivation(.searchTabSelection)
        .tabViewStyle(.tabBarOnly)
        .tint(ProtonColor.primary)
        // Keep the native Liquid-Glass tab bar visible while the photo grid extends underneath it.
        .toolbarBackground(.visible, for: .tabBar)
        .onChange(of: selection) { _, tab in
            MobileTabActivityLog.note(tab: tab)
        }
    }
}

/// The semantic search presentation belongs to the search tab's own navigation content. Attaching
/// `.searchable` to the parent `TabView` propagates ordinary top search chrome into the library on iOS 26.
private struct MobileSearchTabScreen: View {
    @Environment(MobileLibraryModel.self) private var libraryModel
    let isActive: Bool
    @Binding var searchText: String
    @Binding var searchScope: MLSearchScope
    @State private var history = TimelineSearchHistory()
    @State private var suggestions: [TimelineSearchSuggestion] = []
    @State private var recentRepresentatives: [String: PhotoUID] = [:]

    var body: some View {
        MobileTimelineScreen(
            surface: .search,
            isActive: isActive,
            searchText: $searchText,
            searchScope: $searchScope,
            searchHistory: history,
            searchSuggestions: suggestions,
            searchRecentRepresentatives: recentRepresentatives,
            onSelectSearchQuery: selectQuery,
            onClearSearchHistory: clearHistory
        )
        .searchable(
            text: $searchText,
            prompt: Text(L10n.string("search.prompt \(L10n.string("library.title"))"))
        )
        .smartSearchScopes(
            scope: $searchScope,
            availableScopes: libraryModel.smartSearch?.availableSearchScopes ?? [.all],
            isEnabled: libraryModel.smartSearch?.snapshot.isSearchAvailable == true
        )
        .onSubmit(of: .search) { record(searchText) }
        .task(id: searchDiscoveryRevision) {
            let sections = libraryModel.sections
            let recentQueries = Array(history.queries.prefix(6))
            let result: ([TimelineSearchSuggestion], [String: PhotoUID]) = await Task.detached(priority: .utility) {
                let suggestions = TimelineSearchDiscovery.recentDateSuggestions(sections: sections)
                var representatives: [String: PhotoUID] = [:]
                for query in recentQueries {
                    guard !Task.isCancelled else {
                        return ([TimelineSearchSuggestion](), [String: PhotoUID]())
                    }
                    representatives[query] =
                        TimelineSearch.filter(sections, query: query)
                        .last?.items.last?.uid
                }
                return (suggestions, representatives)
            }.value
            guard !Task.isCancelled else { return }
            suggestions = result.0
            recentRepresentatives = result.1
        }
    }

    private func selectQuery(_ query: String) {
        searchText = query
        record(query)
    }

    private func record(_ query: String) {
        var next = history
        next.record(query)
        guard next != history else { return }
        history = next
    }

    private func clearHistory() {
        history.clear()
        recentRepresentatives = [:]
    }

    private var searchDiscoveryRevision: String {
        "\(libraryModel.timelineRevision)|\(history.queries.joined(separator: "\u{1F}"))"
    }
}

private struct MobileUnsupportedDeviceView: View {
    var body: some View {
        Metal3UnsupportedDeviceView(productName: ProductBrand.displayName)
    }
}

/// Metal 3 capability gate (a genuine hardware capability check, not a platform fork - the simulator reports
/// capable via `UIKitTimelineMetalCapability`).
enum MobileMetal3Runtime {
    static func isSupported() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return UIKitTimelineMetalCapability.supportsTimelineGrid(device: device)
    }
}
