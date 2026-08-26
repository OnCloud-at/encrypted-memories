import Observation
import PhotosCore
import SwiftUI
import UIKit

/// Shared iOS/iPadOS selection state machine for the main timeline, collection grids, and map results.
/// Platform screens only provide their item source and the existing backend action; mode transitions, long-press
/// entry, bounded original export and honest error/partial-result state stay identical everywhere.
@MainActor
@Observable
final class MobileGridSelectionController {
    var isSelecting = false
    var selected: Set<PhotoUID> = []
    var sharePayload: MobileSharePayload?
    var partialShare: MobilePartialShare?
    var isExporting = false
    var isFavoriting = false
    var isTrashing = false
    var showTrashConfirm = false
    var actionError: MobileSelectionError?

    var isBusy: Bool { isExporting || isFavoriting || isTrashing }

    func toggleMode() {
        toggleMode(reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    func toggleMode(reduceMotion: Bool) {
        guard !isBusy else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            if isSelecting {
                isSelecting = false
                selected.removeAll(keepingCapacity: false)
            } else {
                isSelecting = true
            }
        }
    }

    func begin(with item: PhotoItem) {
        begin(with: item, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    func begin(with item: PhotoItem, reduceMotion: Bool) {
        guard !isBusy else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            isSelecting = true
            selected.insert(item.uid)
        }
    }

    func toggle(_ item: PhotoItem) {
        guard !isBusy else { return }
        if selected.contains(item.uid) {
            selected.remove(item.uid)
        } else {
            selected.insert(item.uid)
        }
    }

    func applyDragSelection(_ uids: Set<PhotoUID>) {
        guard !isBusy else { return }
        selected = uids
    }

    func finish() {
        finish(reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    func finish(reduceMotion: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            isSelecting = false
            selected.removeAll(keepingCapacity: false)
        }
    }

    func startShare(
        items: [PhotoItem],
        backend: any OriginalFileProvider & PhotoMetadataProvider,
        failureMessage: String = String(localized: "selection.share_failed")
    ) {
        guard !items.isEmpty, !isBusy else { return }
        isExporting = true
        Task {
            let result = await MobileMediaExporter.exportOriginals(items, backend: backend)
            isExporting = false
            if result.urls.isEmpty {
                actionError = MobileSelectionError(message: failureMessage)
            } else if result.failed > 0 {
                partialShare = MobilePartialShare(urls: result.urls, failed: result.failed)
            } else {
                sharePayload = MobileSharePayload(urls: result.urls)
            }
        }
    }

    func performTrash(
        failureMessage: String = String(localized: "selection.trash_failed"),
        _ action: @escaping @MainActor (Set<PhotoUID>) async throws -> Void
    ) {
        let uids = selected
        guard !uids.isEmpty, !isBusy else { return }
        isTrashing = true
        Task {
            defer { isTrashing = false }
            do {
                try await action(uids)
                finish()
            } catch {
                actionError = MobileSelectionError(message: failureMessage)
            }
        }
    }

    func performFavorite(
        failureMessage: String = String(localized: "selection.favorite_failed"),
        _ action: @escaping @MainActor (Set<PhotoUID>) async -> Bool
    ) {
        let uids = selected
        guard !uids.isEmpty, !isBusy else { return }
        isFavoriting = true
        Task {
            defer { isFavoriting = false }
            if !(await action(uids)) {
                actionError = MobileSelectionError(message: failureMessage)
            }
        }
    }
}

/// Identifiable payload for the share sheet: the on-disk file URLs exported from the selection.
struct MobileSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
    let completionURL: URL?

    init(urls: [URL], completionURL: URL? = nil) {
        self.urls = urls
        self.completionURL = completionURL
    }
}

/// A localized, user-facing failure for a selection action, surfaced honestly via an alert.
struct MobileSelectionError: Identifiable {
    let id = UUID()
    let message: String
}

/// A share where some originals could not be downloaded: the successfully-exported URLs plus how many were
/// dropped, so the user is told before the partial share proceeds.
struct MobilePartialShare: Identifiable {
    let id = UUID()
    let urls: [URL]
    let failed: Int
}

/// Native binary confirmations shared by every mobile grid selection surface. A confirmation dialog
/// is an action menu on iPhone and can appear as an anchored popover on iPad; these are yes/no
/// decisions, so the system alert treatment is the consistent platform contract on both form factors.
@MainActor
private struct MobileSelectionAlertsModifier: ViewModifier {
    let selection: MobileGridSelectionController
    let trashTitle: String
    let trashMessage: String
    let trashConfirm: String
    let onConfirmTrash: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "selection.share_partial_title"),
                isPresented: Binding(
                    get: { selection.partialShare != nil },
                    set: { if !$0 { selection.partialShare = nil } }
                ),
                presenting: selection.partialShare
            ) { info in
                Button(String(localized: "selection.share_partial_proceed")) {
                    selection.sharePayload = MobileSharePayload(urls: info.urls)
                }
                Button(L10n.string("action.cancel"), role: .cancel) {
                    MobileMediaExporter.cleanup(info.urls)
                }
            } message: { info in
                Text(String(localized: "selection.share_partial_message \(info.failed)"))
            }
            .alert(
                trashTitle,
                isPresented: Binding(
                    get: { selection.showTrashConfirm },
                    set: { selection.showTrashConfirm = $0 }
                )
            ) {
                Button(trashConfirm, role: .destructive) {
                    onConfirmTrash()
                }
                Button(L10n.string("action.cancel"), role: .cancel) {}
            } message: {
                Text(trashMessage)
            }
            .alert(
                selection.actionError?.message ?? "",
                isPresented: Binding(
                    get: { selection.actionError != nil },
                    set: { if !$0 { selection.actionError = nil } }
                )
            ) {
                Button(L10n.string("action.ok"), role: .cancel) {}
            }
    }
}

extension View {
    /// Installs the selection controller's two binary confirmations and action error exactly once.
    @MainActor
    func mobileSelectionAlerts(
        selection: MobileGridSelectionController,
        trashTitle: String = String(localized: "selection.trash_title"),
        trashMessage: String = String(localized: "selection.trash_message"),
        trashConfirm: String = String(localized: "selection.trash_confirm"),
        onConfirmTrash: @escaping () -> Void
    ) -> some View {
        modifier(
            MobileSelectionAlertsModifier(
                selection: selection,
                trashTitle: trashTitle,
                trashMessage: trashMessage,
                trashConfirm: trashConfirm,
                onConfirmTrash: onConfirmTrash
            ))
    }

    /// Presents the native activity controller directly from UIKit. Wrapping that controller in a
    /// SwiftUI sheet gives SwiftUI and UIKit competing ownership of the same dismissal transition.
    @MainActor
    func mobileSharePresentation(selection: MobileGridSelectionController) -> some View {
        mobileSharePresentation(
            payload: Binding(
                get: { selection.sharePayload },
                set: { selection.sharePayload = $0 }
            ))
    }

    @MainActor
    func mobileSharePresentation(payload: Binding<MobileSharePayload?>) -> some View {
        background {
            MobileActivityPresenter(payload: payload)
        }
    }
}

/// Exports selected media originals to temporary files for a native share sheet.
///
/// It shares real files, never thumbnails. The backend streams each decrypted original straight to its share
/// file; no selected photo/video is materialized as `Data`. Items whose download fails are skipped (the share
/// proceeds with whatever succeeded); if none succeed the caller surfaces the failure honestly.
enum MobileMediaExporter {
    /// The dedicated temp subfolder for share exports, cleared before each run so stale files never pile up.
    private static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ShareExports", isDirectory: true)
    }

    /// Share-sheet completion owns the plaintext lifetime. Cleanup is idempotent because both the
    /// activity completion callback and representable dismantle may run for the same payload.
    static func cleanup(_ urls: [URL]) {
        let directory = exportDirectory.standardizedFileURL
        for url in urls where url.standardizedFileURL.deletingLastPathComponent() == directory {
            try? FileManager.default.removeItem(at: url)
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Writes only the scrubbed Core support report. It shares the canonical transient directory so
    /// completion, dismantle, and cold-launch purge all retain one idempotent cleanup contract.
    static func exportSupportReport(_ data: Data) async -> URL? {
        let directory = exportDirectory
        return await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("Encrypted-Memories-Support.json")
                try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                return url
            } catch {
                return nil
            }
        }.value
    }

    /// The result of an export run: successfully written URLs and the count of downloads that failed.
    struct ExportResult {
        let urls: [URL]
        let failed: Int
    }

    static func exportOriginals(
        _ items: [PhotoItem],
        backend: any OriginalFileProvider & PhotoMetadataProvider
    ) async -> ExportResult {
        guard !items.isEmpty else { return ExportResult(urls: [], failed: 0) }
        let directory = exportDirectory
        let directoryReady = await Task.detached(priority: .utility) {
            let files = FileManager.default
            try? files.removeItem(at: directory)
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                return true
            } catch {
                return false
            }
        }.value
        guard directoryReady else { return ExportResult(urls: [], failed: items.count) }

        // Two selected photos can share an original Proton name. Reserve a unique path before writing
        // so concurrent exports cannot overwrite each other.
        let names = ExportNames()

        let maxConcurrent = 2
        var exported: [URL] = []
        var failed = 0
        var index = 0
        // Bounded task group: at most `maxConcurrent` downloads in flight so a big video selection can't spike RAM.
        await withTaskGroup(of: URL?.self) { group in
            func addNext() {
                guard index < items.count else { return }
                let item = items[index]
                index += 1
                group.addTask { await export(item, backend: backend, names: names, into: directory) }
            }
            for _ in 0..<min(maxConcurrent, items.count) { addNext() }
            for await url in group {
                if let url { exported.append(url) } else { failed += 1 }
                addNext()
            }
        }
        if exported.isEmpty { cleanup([]) }
        return ExportResult(urls: exported, failed: failed)
    }

    private static func export(
        _ item: PhotoItem,
        backend: any OriginalFileProvider & PhotoMetadataProvider,
        names: ExportNames,
        into directory: URL
    ) async -> URL? {
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try await backend.writeOriginal(for: item.uid, to: staging)
            try Task.checkCancellation()
            // The decrypted Proton filename is authoritative. Preserve it when available, and use the
            // generated fallback if metadata lookup fails.
            let meta = try? await backend.metadata(for: item.uid)
            // Derive a missing extension from the bounded header, then use the link MIME as a secondary signal.
            let header = try fileHeader(staging)
            let ext = OriginalFileNaming.resolvedExtension(
                filename: meta?.filename, mimeType: meta?.mimeType, header: header,
                fallbackMediaType: item.mediaType, isVideo: item.isVideo
            )
            let desired = OriginalFileNaming.exportFilename(
                metadataFilename: meta?.filename, fallbackBase: fallbackBase(for: item), ext: ext
            )
            let url = directory.appendingPathComponent(await names.unique(desired))
            try FileManager.default.moveItem(at: staging, to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func fileHeader(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 64) ?? Data()
    }

    /// Generates a fallback base name when Proton metadata has no filename. The timestamp and node suffix
    /// avoid collisions before the unique-name actor assigns the final path.
    static func fallbackBase(for item: PhotoItem) -> String {
        let stamp = Self.stampFormatter.string(from: item.captureTime)
        let suffix = String(item.uid.nodeID.suffix(6))
        return "Encrypted-Memories-\(stamp)-\(suffix)"
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// Serialises on-disk name assignment across the concurrent export/save tasks so two files that resolve to
/// the same original name (a real collision, e.g. two `IMG_0001.HEIC`) get `IMG_0001 2.HEIC` etc. instead of
/// clobbering each other's temp URL. Case-insensitive to match the (typically case-insensitive) filesystem.
/// Mirrors macOS `MainView.uniqueName`.
actor ExportNames {
    private var used: Set<String> = []

    func unique(_ name: String) -> String {
        if reserve(name) { return name }
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if reserve(candidate) { return candidate }
            n += 1
        }
    }

    /// Records `name` and returns true if it was free; false if already taken.
    private func reserve(_ name: String) -> Bool {
        used.insert(name.lowercased()).inserted
    }
}

/// A stable UIKit presentation host for the native activity controller.
///
/// `UIActivityViewController` dismisses itself after cancellation or completion. Presenting it as
/// the content of SwiftUI's `.sheet` gives `UIKitPopoverBridge` a second dismissal owner. iOS 26.6
/// traps when both transitions run together. This host stays in the SwiftUI hierarchy and lets
/// UIKit own the activity controller's complete presentation lifecycle.
struct MobileActivityPresenter: UIViewControllerRepresentable {
    @Binding var payload: MobileSharePayload?

    @MainActor
    final class HostController: UIViewController {
        var onAppearance: (() -> Void)?

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppearance?()
        }
    }

    @MainActor
    final class Coordinator {
        private var pendingPayload: MobileSharePayload?
        private var activePayload: MobileSharePayload?
        private var payloadBinding: Binding<MobileSharePayload?>?
        private weak var activeController: UIActivityViewController?

        func update(
            payload: MobileSharePayload?,
            binding: Binding<MobileSharePayload?>,
            presenter: HostController
        ) {
            payloadBinding = binding
            pendingPayload = payload?.id == activePayload?.id ? nil : payload
            presentIfPossible(from: presenter)
        }

        func hostDidAppear(_ presenter: HostController) {
            presentIfPossible(from: presenter)
        }

        func prepareController(
            for payload: MobileSharePayload,
            binding: Binding<MobileSharePayload?>,
            presenter: UIViewController
        ) -> UIActivityViewController {
            begin(payload: payload, binding: binding)

            let controller = UIActivityViewController(
                activityItems: payload.urls,
                applicationActivities: nil
            )
            activeController = controller
            controller.completionWithItemsHandler = completionHandler(for: payload.id)

            if let popover = controller.popoverPresentationController {
                let bounds = presenter.view.bounds
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: bounds.midX,
                    y: bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            return controller
        }

        /// Internal seams let the iOS test invoke the completion path without starting the
        /// system share service, which continues asynchronous item inspection after initialization.
        func begin(
            payload: MobileSharePayload,
            binding: Binding<MobileSharePayload?>
        ) {
            payloadBinding = binding
            activePayload = payload
        }

        func completionHandler(
            for payloadID: UUID
        ) -> UIActivityViewController.CompletionWithItemsHandler {
            { [weak self] _, _, _, _ in
                self?.complete(payloadID: payloadID)
            }
        }

        func dismantle(presenter: HostController) {
            let urls = (activePayload?.urls ?? []) + (pendingPayload?.urls ?? [])
            pendingPayload = nil
            activePayload = nil
            payloadBinding = nil

            guard let controller = activeController else {
                MobileMediaExporter.cleanup(urls)
                return
            }
            activeController = nil
            controller.completionWithItemsHandler = nil
            presenter.dismiss(animated: false) {
                MobileMediaExporter.cleanup(urls)
            }
        }

        private func presentIfPossible(from presenter: HostController) {
            guard activeController == nil,
                presenter.viewIfLoaded?.window != nil,
                presenter.presentedViewController == nil,
                let pendingPayload,
                let payloadBinding
            else {
                return
            }
            self.pendingPayload = nil
            let controller = prepareController(
                for: pendingPayload,
                binding: payloadBinding,
                presenter: presenter
            )
            presenter.present(controller, animated: true)
        }

        private func complete(payloadID: UUID) {
            guard activePayload?.id == payloadID else { return }
            let urls = activePayload?.urls ?? []
            let completionURL = activePayload?.completionURL
            activePayload = nil
            activeController = nil
            MobileMediaExporter.cleanup(urls)

            if let payloadBinding, payloadBinding.wrappedValue?.id == payloadID {
                payloadBinding.wrappedValue = nil
            }
            payloadBinding = nil
            if let completionURL {
                UIApplication.shared.open(completionURL)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> HostController {
        let presenter = HostController()
        presenter.onAppearance = { [weak presenter, weak coordinator = context.coordinator] in
            guard let presenter else { return }
            coordinator?.hostDidAppear(presenter)
        }
        return presenter
    }

    func updateUIViewController(_ presenter: HostController, context: Context) {
        context.coordinator.update(payload: payload, binding: $payload, presenter: presenter)
    }

    static func dismantleUIViewController(_ presenter: HostController, coordinator: Coordinator) {
        presenter.onAppearance = nil
        coordinator.dismantle(presenter: presenter)
    }
}
