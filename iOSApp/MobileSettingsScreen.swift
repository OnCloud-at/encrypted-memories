import DesignSystemCore
import Foundation
import MLSearchCore
import PhotoLibraryBackupAdapter
import Photos
import PhotosCore
import PhotosUI
import ProtonDriveBackend
import SwiftUI
import TimelineCore
import UIKit
import UploadCore
import UploadFeature

/// Account, library status, cache and sign-out settings for the mobile app.
struct MobileSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var sessionModel: MobileSessionModel
    /// Settings reads lightweight state from the `@Observable` model, so a large timeline snapshot does not
    /// invalidate this screen.
    @Environment(MobileLibraryModel.self) private var libraryModel
    /// Shared Proton account info populated by the backend's account-data cache.
    @State private var account = AccountInfo.shared

    @State private var cacheSize: Int64 = 0
    @State private var isClearingCache = false
    @State private var confirmSignOut = false
    @State private var confirmClearCache = false
    @State private var showsBugReport = false
    let showsDismissButton: Bool

    init(showsDismissButton: Bool = false) {
        self.showsDismissButton = showsDismissButton
    }

    var body: some View {
        NavigationStack {
            List {
                accountSection
                tipJarSection
                featuresSection
                cacheSection
                supportSection
                signOutSection
                brandFooter
            }
            .mobileNavigationTitle(String(localized: "tab.settings"))
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("action.done")) { dismiss() }
                    }
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await refreshCacheSize()
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(10))
                    } catch {
                        return
                    }
                    await refreshCacheSize()
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await libraryModel.refreshAccountInfo()
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(300))
                    } catch {
                        return
                    }
                    await libraryModel.refreshAccountInfo()
                }
            }
            .signOutConfirmation(isPresented: $confirmSignOut) { sessionModel.signOut() }
            .alert(
                String(localized: "settings.clear_cache_title"),
                isPresented: $confirmClearCache
            ) {
                Button(String(localized: "settings.clear_cache"), role: .destructive) { clearCache() }
                Button(L10n.string("action.cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "settings.clear_cache_message"))
            }
            .sheet(isPresented: $showsBugReport) { MobileBugReportSheet() }
        }
    }

    // MARK: - Sections

    /// Account identity and storage quota when the backend has decoded them.
    @ViewBuilder private var accountSection: some View {
        if account.primaryEmail != nil || (account.driveUsedSpaceBytes != nil && account.driveMaxSpaceBytes != nil) {
            Section(String(localized: "settings.section_account")) {
                if let email = account.primaryEmail {
                    LabeledContent(String(localized: "settings.account_email")) {
                        Text(email).foregroundStyle(ProtonColor.textWeak)
                    }
                }
                if let used = account.driveUsedSpaceBytes,
                    let max = account.driveMaxSpaceBytes,
                    max > 0
                {
                    let quota = ProtonStorageQuotaFormatter.presentation(
                        usedBytes: used,
                        maximumBytes: max
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(String(localized: "settings.storage")) {
                            Text(String(localized: "settings.storage_usage \(quota.used) \(quota.maximum)"))
                                .monospacedDigit()
                                .foregroundStyle(ProtonColor.textWeak)
                        }
                        ProgressView(value: Double(min(used, max)), total: Double(max))
                            .tint(ProtonColor.primary)
                    }
                }
            }
        }
    }

    private var tipJarSection: some View {
        Section {
            NavigationLink {
                MobileTipJarScreen()
            } label: {
                Label(L10n.string("settings.tip_jar_title"), systemImage: "heart")
            }
        }
    }

    /// User-facing product features live under one stable heading on iPhone and iPad. The feature
    /// implementations remain shared; this section only gives their entry points a consistent hierarchy.
    @ViewBuilder private var featuresSection: some View {
        Section {
            if let smartSearch = libraryModel.smartSearch {
                NavigationLink {
                    MobileSmartSearchScreen(controller: smartSearch)
                } label: {
                    Label(MLSmartSearchPresentation.productName, systemImage: "sparkle.magnifyingglass")
                }
            }
            if let photoBackup = libraryModel.photoBackup {
                VStack(alignment: .leading, spacing: 12) {
                    Label(String(localized: "settings.section_backup"), systemImage: "icloud.and.arrow.up")
                        .font(.headline)
                    MobilePhotoBackupRows(controller: photoBackup)
                }
            }
            if let albumSync = libraryModel.albumSync {
                NavigationLink {
                    MobileAlbumSyncScreen(controller: albumSync)
                } label: {
                    Label(String(localized: "settings.albumsync_row"), systemImage: "rectangle.stack.badge.plus")
                }
            }
            backupStatusRow
        } header: {
            Text(String(localized: "settings.section_features"))
        } footer: {
            if libraryModel.photoBackup?.isEnabled == true {
                Text(String(localized: "settings.photos_backup_background_note"))
            }
        }
    }

    @ViewBuilder private var backupStatusRow: some View {
        let status = BackupStatus(
            manualUploadCheck: libraryModel.facade?.uploadCoordinator.preparationStatus ?? UploadPreparationStatus()
        )
        let total = status.totalConsidered ?? 0
        if status.isActive || total > 0 || status.needsAttentionCount > 0 {
            HStack(spacing: 10) {
                Image(systemName: status.isActive ? "arrow.trianglehead.2.clockwise" : "checkmark.shield")
                    .foregroundStyle(status.isActive ? ProtonColor.primary : ProtonColor.textWeak)
                    .frame(width: 18)
                    .spinsWhileActive(status.isActive, period: 1.7)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(status.localizedTitle)
                            .foregroundStyle(ProtonColor.textNorm)
                        Spacer()
                        if total > 0 {
                            Text(L10n.string("settings.upload_check_progress \(status.checked) \(total)"))
                                .font(.footnote)
                                .foregroundStyle(ProtonColor.textWeak)
                                .monospacedDigit()
                        }
                    }
                    if total > 0 {
                        if let fraction = status.fractionCompleted {
                            ProgressView(value: fraction)
                                .tint(ProtonColor.primary)
                        } else {
                            ProgressView()
                                .tint(ProtonColor.primary)
                        }
                        backupStatusDetail(status)
                    } else if status.needsAttentionCount > 0 {
                        backupStatusDetail(status)
                    }
                }
            }
        } else {
            Text(L10n.string("settings.upload_check_idle_help"))
                .font(.footnote)
                .foregroundStyle(ProtonColor.textWeak)
        }
    }

    @ViewBuilder private func backupStatusDetail(_ status: BackupStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if status.alreadyBackedUp > 0 {
                Text(L10n.string("settings.upload_check_duplicates \(status.alreadyBackedUp)"))
            }
            if status.needsAttentionCount > 0 {
                Text(L10n.string("settings.upload_check_attention \(status.needsAttentionCount)"))
            }
        }
        .font(.footnote)
        .foregroundStyle(ProtonColor.textWeak)
        .monospacedDigit()
    }

    /// On-disk encrypted thumbnail-cache size and clear action.
    @ViewBuilder private var cacheSection: some View {
        Section(String(localized: "settings.section_cache")) {
            LabeledContent(String(localized: "settings.cache_size")) {
                Text(L10n.fileSize(cacheSize))
                    .monospacedDigit()
                    .foregroundStyle(ProtonColor.textWeak)
            }
            Button(role: .destructive) {
                confirmClearCache = true
            } label: {
                HStack {
                    Text(String(localized: "settings.clear_cache"))
                    Spacer()
                    if isClearingCache { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isClearingCache)
        }
    }

    @ViewBuilder private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                confirmSignOut = true
            } label: {
                Label(L10n.string("action.sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    @ViewBuilder private var supportSection: some View {
        Section {
            Button {
                showsBugReport = true
            } label: {
                Label(L10n.string("settings.bug_report_action"), systemImage: "ladybug")
            }
        } footer: {
            Text(L10n.string("settings.bug_report_privacy"))
        }
    }

    @ViewBuilder private var brandFooter: some View {
        Section {
            EmptyView()
        } footer: {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    MemoriesBrandMark(height: 28)
                    Text(ProductBrand.displayName)
                        .font(.footnote)
                        .foregroundStyle(ProtonColor.textHint)
                    AppBuildInfoLabel()
                }
                Spacer()
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Actions

    private func refreshCacheSize() async {
        cacheSize = await libraryModel.cacheDiskSizeBytes()
    }

    private func clearCache() {
        isClearingCache = true
        Task {
            await libraryModel.clearCache()
            await refreshCacheSize()
            isClearingCache = false
        }
    }
}

private struct MobileBugReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var supportExport: MobileSharePayload?
    @State private var isPreparingReport = false
    @State private var errorMessage: String?

    private static let issueURL = URL(
        string: "https://github.com/OnCloud-at/encrypted-memories/issues"
    )!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.string("settings.bug_report_instructions"))
                    Button {
                        Task { await exportSupportReport() }
                    } label: {
                        HStack {
                            Label(
                                L10n.string("settings.bug_report_download"),
                                systemImage: "square.and.arrow.down"
                            )
                            Spacer()
                            if isPreparingReport { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(isPreparingReport)
                    Button {
                        openURL(Self.issueURL)
                    } label: {
                        Label(
                            L10n.string("settings.bug_report_support"),
                            systemImage: "arrow.up.right.square"
                        )
                    }
                } footer: {
                    Text(L10n.string("settings.bug_report_privacy"))
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .mobileNavigationTitle(L10n.string("settings.bug_report_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("action.done")) { dismiss() }
                }
            }
            .mobileSharePresentation(payload: $supportExport)
        }
    }

    @MainActor private func exportSupportReport() async {
        guard !isPreparingReport else { return }
        isPreparingReport = true
        errorMessage = nil
        defer { isPreparingReport = false }
        do {
            let data = try await SupportDiagnosticsExporter.makeJSONData()
            guard let url = await MobileMediaExporter.exportSupportReport(data) else {
                errorMessage = L10n.string("settings.bug_report_export_failed")
                return
            }
            supportExport = MobileSharePayload(urls: [url])
        } catch {
            errorMessage = L10n.string("settings.bug_report_export_failed")
        }
    }
}

private struct MobileTipJarScreen: View {
    var body: some View {
        List {
            Section {
                TipJarView()
            } footer: {
                Text(L10n.string("settings.tip_jar_footer"))
            }
        }
        .mobileNavigationTitle(L10n.string("settings.tip_jar_title"))
    }
}

// MARK: - Photos library backup (shared cross-platform controller, native mobile presentation)

/// Enable/permission/progress rows for Photos-library backup. All state, counts, and wording come
/// from the shared `PhotoLibraryBackupController` + `BackupStatus`; this view is layout only.
private struct MobilePhotoBackupRows: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppSettingsKey.keepDisplayAwakeDuringForegroundBackup)
    private var keepDisplayAwake = AppSettingsDefault.keepDisplayAwakeDuringForegroundBackup
    @State var controller: PhotoLibraryBackupController
    @State private var rowModel = BackupStatusRowModel()
    @State private var showFailedList = false

    var body: some View {
        Group {
            if !controller.isAvailable {
                Text(String(localized: "settings.photos_backup_unavailable"))
                    .font(.footnote)
                    .foregroundStyle(ProtonColor.textWeak)
            } else if !controller.isEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("settings.photos_backup_explainer"))
                        .font(.footnote)
                        .foregroundStyle(ProtonColor.textWeak)
                    if controller.accessState == .denied || controller.accessState == .restricted {
                        Text(String(localized: "settings.photos_backup_denied_ios"))
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Button(String(localized: "settings.photos_backup_open_settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } else {
                        Button(L10n.string("settings.photos_backup_enable")) {
                            Task {
                                await controller.enableBackup()
                            }
                        }
                        .foregroundStyle(ProtonColor.primary)
                    }
                }
            } else {
                enabledStatusRows
            }
        }
        // This surface contains several independent actions in one Form row. Use borderless buttons so
        // the row style does not forward one tap to every descendant action.
        .buttonStyle(.borderless)
    }

    /// Keeps the headline and detail slots stable while text changes. `BackupStatusPresentation` supplies
    /// localized wording and counts for every platform.
    @ViewBuilder private var enabledStatusRows: some View {
        let display = rowModel.displayed

        HStack(alignment: .top, spacing: 12) {
            statusIcon(display)
                .frame(width: 20, height: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(display.localizedHeadline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ProtonColor.textNorm)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: display.headlineKey)

                statusDetails(display)

                if let retry = display.localizedRetryDetail {
                    Text(retry)
                        .font(.caption)
                        .foregroundStyle(ProtonColor.textWeak)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let systemIssue = display.localizedSystemIssue {
                    Text(systemIssue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let dedupeWarning = display.localizedDedupeWarning {
                    Text(dedupeWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let attention = display.localizedAttention {
                    // Tappable: opens a plain-language list of exactly which files failed and why.
                    Button {
                        showFailedList = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(attention)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let waiting = display.localizedWaitingDetail {
                    Button {
                        showFailedList = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(waiting)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundStyle(ProtonColor.textWeak)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                if controller.isUserPaused {
                    Button(L10n.string("settings.photos_backup_resume")) {
                        Task {
                            await controller.resumeBackup()
                            PhotoBackupBackgroundCoordinator.shared.backupResumed(controller: controller)
                        }
                    }
                    .font(.footnote)
                } else if controller.isSyncing {
                    Button(L10n.string("settings.photos_backup_pause")) {
                        PhotoBackupBackgroundCoordinator.shared.backupPaused()
                        controller.pauseBackup()
                    }
                    .font(.footnote)
                } else {
                    Button(String(localized: "settings.photos_backup_sync_now")) {
                        Task {
                            await controller.retryFailedAndSync()
                        }
                    }
                    .font(.footnote)
                }
                if let skipped = display.localizedRemoteDeletionDetail {
                    BackupRemoteDeletionInfoButton(message: skipped)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.28),
            value: display.detailLayout
        )
        .onAppear { rowModel.ingest(controller.status) }
        .onChange(of: controller.status) { _, status in rowModel.ingest(status) }
        .onDisappear { rowModel.cancel() }
        .sheet(isPresented: $showFailedList) {
            MobileFailedBackupSheet(controller: controller)
        }

        if let message = controller.lastMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        if controller.accessState == .limited {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("settings.photos_backup_limited"))
                    .font(.footnote)
                    .foregroundStyle(ProtonColor.textWeak)
                Button(String(localized: "settings.photos_backup_manage_selection")) {
                    presentLimitedLibraryPicker()
                }
                .font(.footnote)
            }
        }

        Toggle(isOn: $keepDisplayAwake) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("settings.photos_backup_keep_display_awake"))
                Text(L10n.string("settings.photos_backup_keep_display_awake_detail"))
                    .font(.caption)
                    .foregroundStyle(ProtonColor.textWeak)
            }
        }
        .onChange(of: keepDisplayAwake) { _, _ in
            PhotoBackupBackgroundCoordinator.shared.displayPreferenceDidChange()
        }

        Button(L10n.string("settings.photos_backup_disable"), role: .destructive) {
            PhotoBackupBackgroundCoordinator.shared.backupStopped()
            controller.disableBackup()
        }
        .font(.footnote)
    }

    /// Scanning and terminal states stay compact. A known-total active pass expands once, then
    /// reserves its internal subtitle/transfer/bar slots so per-file updates cannot pump the row.
    @ViewBuilder private func statusDetails(_ display: BackupStatusPresentation) -> some View {
        if display.detailLayout == .progress {
            VStack(alignment: .leading, spacing: 3) {
                subtitleSlot(display, reservesSpace: true)
                transferSlot(display, reservesSpace: true)
                progressSlot(display)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                subtitleSlot(display, reservesSpace: false)
                transferSlot(display, reservesSpace: false)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder private func subtitleSlot(
        _ display: BackupStatusPresentation,
        reservesSpace: Bool
    ) -> some View {
        if reservesSpace {
            let subtitle = display.localizedSubtitle
            Text(verbatim: subtitle ?? "\u{00a0}")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(ProtonColor.textWeak)
                .contentTransition(.numericText())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(subtitle == nil ? 0 : 1)
                .accessibilityHidden(subtitle == nil)
        } else if let subtitle = display.localizedSubtitle {
            Text(subtitle)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(ProtonColor.textWeak)
                .contentTransition(.numericText())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func transferSlot(
        _ display: BackupStatusPresentation,
        reservesSpace: Bool
    ) -> some View {
        if reservesSpace {
            let transfer = display.localizedTransferDetail
            Text(verbatim: transfer ?? "\u{00a0}")
                .font(.caption.monospacedDigit())
                .foregroundStyle(ProtonColor.primary)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(transfer == nil ? 0 : 1)
                .accessibilityHidden(transfer == nil)
        } else if let transfer = display.localizedTransferDetail {
            Text(transfer)
                .font(.caption.monospacedDigit())
                .foregroundStyle(ProtonColor.primary)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The row's single icon. Only `.activity` spins - there is never a second activity indicator.
    @ViewBuilder private func statusIcon(_ display: BackupStatusPresentation) -> some View {
        switch display.accessory {
        case .activity:
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .foregroundStyle(ProtonColor.primary)
                .spinsWhileActive(true, period: 1.7)
        case .attention:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .paused:
            Image(systemName: "pause.circle")
                .foregroundStyle(ProtonColor.textWeak)
        case .waiting:
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(ProtonColor.textWeak)
        case .notice:
            Image(systemName: "info.circle")
                .foregroundStyle(ProtonColor.textWeak)
        case .success:
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(ProtonColor.primary)
        case .idle:
            Image(systemName: "checkmark.shield")
                .foregroundStyle(ProtonColor.textWeak)
        }
    }

    /// Determinate bar matching the percentage directly above it while bytes move; otherwise it shows
    /// queue-wide completion. An empty reserved slot keeps the row stable. Scanning stays barless.
    @ViewBuilder private func progressSlot(_ display: BackupStatusPresentation) -> some View {
        if let fraction = display.progressBarFraction, display.isActive || display.accessory == .paused {
            ProgressView(value: fraction)
                .tint(ProtonColor.primary)
                .frame(height: 4)
                .accessibilityLabel(display.localizedProgressBarLabel ?? "")
        } else {
            Color.clear.frame(height: 4)
        }
    }

    /// The system's limited-library selection UI (iOS/iPadOS only - the picker is UIKit-hosted,
    /// which is exactly why this call lives in the app layer, not the shared adapter).
    private func presentLimitedLibraryPicker() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let root = scenes.first?.keyWindow?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }
}

/// Tapping "N nicht gesichert" opens this: a plain-language list of exactly which files failed and
/// why. Deleted-from-device files are marked permanent (retrying can't help and no retry is offered
/// for them); everything else can be retried here and is also auto-retried on the next app launch.
private struct MobileFailedBackupSheet: View {
    let controller: PhotoLibraryBackupController
    @Environment(\.dismiss) private var dismiss
    @State private var items: [BackupFailedItem] = []

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.string("backup.failed_sheet_empty"), systemImage: "checkmark.shield")
                    }
                } else {
                    List {
                        Section {
                            ForEach(items) { item in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: item.isPermanent ? "trash.slash" : "arrow.clockwise.circle")
                                        .foregroundStyle(item.isPermanent ? ProtonColor.textWeak : .orange)
                                        .font(.body)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.filename)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(item.reason)
                                            .font(.caption)
                                            .foregroundStyle(ProtonColor.textWeak)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let retryDescription = item.retryDescription {
                                            Text(retryDescription)
                                                .font(.caption2)
                                                .foregroundStyle(ProtonColor.textWeak)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if item.isPermanent {
                                        Button(L10n.string("backup.failed_item_dismiss")) {
                                            controller.dismissFailedItem(item)
                                            items.removeAll { $0.id == item.id }
                                        }
                                        .tint(ProtonColor.textWeak)
                                    }
                                }
                            }
                        } footer: {
                            Text(L10n.string("backup.failed_sheet_footer"))
                        }
                    }
                }
            }
            .mobileNavigationTitle(L10n.string("backup.failed_sheet_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("backup.failed_sheet_done")) { dismiss() }
                }
                if controller.hasRetryableFailures {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("backup.failed_sheet_retry")) {
                            Task {
                                await controller.retryFailedAndSync()
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { items = controller.failedItems() }
    }
}
