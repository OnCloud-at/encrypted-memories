import AppKit
import GridCore
import PhotosCore
import UniformTypeIdentifiers

/// Owns the native drag-out (drag-to-Finder / drag-into-apps) interaction for the macOS Metal grid.
///
/// Strategy: at lift-off the controller creates one `NSFilePromiseProvider` per dragged item and
/// begins staging immediately (`DragOutStager.beginPrefetch`, Strategy A) while the user is still
/// holding the drag. When the drop destination asks for delivery, AppKit invokes
/// `writePromiseTo` on a background queue; the controller awaits the staged plaintext file and
/// copies it to the promised URL. Delivery is promise-backed-by-a-staged-copy rather than a move:
/// the plaintext staged file stays available for the rest of the session (another receiver could
/// still demand it). macOS resolves file promises only after the dragging session ends, so the
/// controller tears the session down on a grace delay (see `teardownGraceNanoseconds`) instead of
/// immediately; the grace cleanup deletes every staged file that was not delivered.
/// The delivered copy is therefore a transient plaintext duplicate that exists only from delivery
/// until the destination takes ownership (plus the bounded grace window).
///
/// MARQUEE ARBITRATION: a background press that turns into a drag belongs to the marquee. A press
/// on a TILE that crosses the drag threshold claims the gesture for drag-out instead, and the
/// spacer suppresses both the marquee and the trailing click for that gesture. See
/// `MetalGridDocumentSpacer.mouseDragged`.
@MainActor
final class MetalGridDragOutController: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    private weak var spacer: NSView?
    private let coordinator: MetalGridCoordinator
    private var itemForUID: ((PhotoUID) -> PhotoItem?)?
    /// Resolves the pressed tile's dragged set (a multi-selection press lifts every selected
    /// original, ordered by the grid's flat order; a solo press lifts just the pressed item).
    private var liftItems: ((PhotoItem) -> [PhotoItem])?
    private var onFailed: ((DragOutFailureKind) -> Void)?
    private let fileProvider: any OriginalFileProvider
    private var stager: DragOutStager?
    private var reportedFailure = false
    /// Filenames resolved from metadata during the drag; a promise whose name is requested before
    /// its async lookup lands uses the synchronous fallback instead (Finder renames collisions).
    private var cachedFilenames: [PhotoUID: String] = [:]
    private var items: [PhotoUID: PhotoItem] = [:]

    /// Per-promise session payload attached to every `NSFilePromiseProvider`. Promise callbacks
    /// (`writePromiseTo`, `fileNameForType`) arrive after the session has visually ended on
    /// macOS; reading `self.stager` there would miss the NEXT session's stager (late delivery of
    /// the previous drag) or nil (after teardown). Capturing the stager per provider at creation
    /// keeps every delivery bound to the session that promised it. All members are Sendable.
    private struct PromisePayload {
        let uid: PhotoUID
        let stager: DragOutStager
    }

    init(
        spacer: NSView,
        coordinator: MetalGridCoordinator,
        fileProvider: any OriginalFileProvider,
        itemForUID: @escaping (PhotoUID) -> PhotoItem?,
        liftItems: @escaping (PhotoItem) -> [PhotoItem],
        onFailed: @escaping (DragOutFailureKind) -> Void
    ) {
        self.spacer = spacer
        self.coordinator = coordinator
        self.fileProvider = fileProvider
        self.itemForUID = itemForUID
        self.liftItems = liftItems
        self.onFailed = onFailed
        super.init()
    }

    deinit {
        // Nonisolated deinit: capture the stager, then let its actor run the final teardown. No
        // main-actor hop is needed because `DragOutStager` is an actor and touches no UI state
        // (compiles under Swift 6 strict concurrency; see `UIKitTimelineGridDragOutController.deinit`
        // for the iOS counterpart that must hop for `interaction?.isEnabled`).
        let stager = stager
        Task {
            await stager?.finishAndCleanup()
        }
    }

    /// The on-demand staging directory for drag-out originals (matches the iOS controller).
    private static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DragOut", isDirectory: true)
    }

    /// A fresh per-session staging subdirectory keeps concurrent sessions from sweeping each
    /// other's in-flight downloads: the stager's orphan sweep removes stale `.download` files,
    /// and a second drag reusing the shared directory could delete the first session's files.
    private static func makeSessionStagingDirectory() -> URL {
        Self.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Delays session teardown after the drag visually ends: macOS resolves file promises only
    /// after `draggingSession(endedAt:)`, so an immediate cleanup would cancel in-flight staging
    /// (4K/2 GB videos) and fail late `writePromiseTo` deliveries. Bounded so plaintext staged
    /// files persist at most this long after a session ends.
    private static let teardownGraceNanoseconds: UInt64 = 60_000_000_000

    /// Shrinks the ghost slightly below the tile so the drag visually lifts off the grid.
    private static let draggingGhostInset: CGFloat = 3

    /// Renders the tile thumbnail exactly as the grid draws it at rest, so the lifted photo reads
    /// as "the tile took off": the same `TileContentFitter` geometry for the slot's CURRENT
    /// effective display mode (letterboxed content rect in aspectFit, UV-window center crop in
    /// squareFillCrop) and the same slot-side-derived corner radius. Returns the image plus the
    /// frame it must occupy in the spacer's coordinate system, so non-square media keeps its
    /// aspect in both modes instead of stretching into the square slot frame. Pure drawing: no
    /// shadows, borders, or text (nothing that competes with the receiver-owned drop badge).
    private static func tileGhost(
        from cg: CGImage, slotFrame: CGRect, displayMode: TileContentDisplayMode
    ) -> (image: NSImage, frame: CGRect) {
        let fit = TileContentFitter.fit(
            slotRect: slotFrame,
            mediaPixelSize: CGSize(width: cg.width, height: cg.height),
            displayMode: displayMode)
        let rect = fit.contentRect
        let size = rect.size
        guard size.width > 0, size.height > 0, cg.width > 0, cg.height > 0 else {
            return (NSImage(size: size, flipped: false) { _ in true }, rect)
        }
        // The grid derives the corner radius from the SLOT side (not the content rect); clamp to
        // the content rect because an extreme letterbox can make the slot-derived radius exceed
        // half the drawn side.
        let radius = min(
            GridCornerRadiusPolicy.radius(
                forSlotSidePoints: min(slotFrame.width, slotFrame.height)),
            min(size.width, size.height) * 0.5)
        // Map the fitter's UV window back to the full source: draw the whole image scaled so
        // the sampled UV window lands exactly in the content rect (identity UV in aspectFit,
        // the center-crop window in squareFillCrop). The UV insets are symmetric, so the y
        // flip between Metal and CG is invisible.
        let uvWidth = max(Double(fit.uvMax.x - fit.uvMin.x), 0.0001)
        let uvHeight = max(Double(fit.uvMax.y - fit.uvMin.y), 0.0001)
        let drawRect = CGRect(
            x: size.width * (-Double(fit.uvMin.x) / uvWidth),
            y: size.height * (-Double(fit.uvMin.y) / uvHeight),
            width: size.width / uvWidth,
            height: size.height / uvHeight)
        // Block-based image (Apple's sanctioned lockFocus replacement): AppKit rasterizes the
        // handler lazily on first draw, so liftoff does not pay a synchronous bitmap render per
        // tile, and the handler renders at the destination's backing scale, so the ghost stays
        // crisp on Retina. The handler may run on whatever thread draws the image; it only
        // touches immutable captured values and the drawing context.
        let image = NSImage(size: size, flipped: false) { _ in
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.addPath(
                    CGPath(
                        roundedRect: CGRect(origin: .zero, size: size),
                        cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.clip()
                context.draw(cg, in: drawRect)
                context.restoreGState()
            }
            return true
        }
        return (image, rect)
    }

    // MARK: - Session begin

    /// Attempts to claim a threshold-crossing press for drag-out. Returns true when a native
    /// dragging session began (the caller then suppresses the marquee and the trailing click);
    /// false when the press is not on a tile, so the marquee path stays untouched.
    @discardableResult
    func beginDrag(contentPoint: CGPoint, event: NSEvent) -> Bool {
        guard
            let spacer,
            let pressedHit = coordinator.hitTestDragOut(contentPoint: contentPoint),
            let item = itemForUID?(pressedHit.uid)
        else { return false }
        let dragged = liftItems?(item) ?? [item]
        guard !dragged.isEmpty else { return false }

        let stager = DragOutStager(
            fileProvider: fileProvider, stagingDirectory: Self.makeSessionStagingDirectory())
        self.stager = stager
        reportedFailure = false
        items = Dictionary(uniqueKeysWithValues: dragged.map { ($0.uid, $0) })
        cachedFilenames.removeAll()

        // Kick the disk-space preflight + staging now. The system's promise callbacks can arrive
        // before this Task parks the job registry, which `DragOutStager.awaitStaged` tolerates.
        let prefetchedItems = dragged
        Task { @MainActor in
            let decision = await stager.beginPrefetch(items: prefetchedItems)
            if !decision.isAllowed {
                self.reportFailure(.insufficientSpace)
            }
        }
        // Resolve real filenames while the user is still holding the drag; a fast delivery can
        // still race this and get the fallback name (benign - Finder deduplicates collisions).
        prefetchFilenames(for: dragged)

        let providers = dragged.map { item in
            let provider = NSFilePromiseProvider(
                fileType: Self.promiseFileType(for: item), delegate: self)
            provider.userInfo = PromisePayload(uid: item.uid, stager: stager)
            return provider
        }
        let draggingItems = providers.map { NSDraggingItem(pasteboardWriter: $0) }
        // Ghost imagery: one dragging item per photo, framed like the pressed tile in the SPACER's
        // coordinate system (AppKit: "all coordinate properties in the NSDraggingItem are in the
        // coordinate system of view" - the view that begins the session). Content -> spacer adds
        // the leading obstruction inset to x. With several photos, the system composites them
        // into the .pile formation with slight offsets. The image + frame pair reproduces the
        // tile's at-rest fit for the CURRENT effective display mode, so non-square media keeps
        // its aspect (letterbox or center-crop) instead of stretching into the square slot.
        let anchorSpacerFrame = coordinator.cellRect(flatIndex: pressedHit.flatIndex)?
            .offsetBy(dx: coordinator.leadingObstructionInset, dy: 0)
        let ghostDisplayMode = coordinator.effectiveDisplayMode
        if let anchorSpacerFrame {
            for (index, draggingItem) in draggingItems.enumerated() {
                if let cg = coordinator.thumbnailImage(for: dragged[index].uid) {
                    // Uniform inset on the (always square) slot keeps the slot square, so the
                    // fitted ghost shrinks proportionally - the slight "lift off the grid" gap
                    // stays intact.
                    let (ghostImage, contentFrame) = Self.tileGhost(
                        from: cg,
                        slotFrame: anchorSpacerFrame.insetBy(
                            dx: Self.draggingGhostInset, dy: Self.draggingGhostInset),
                        displayMode: ghostDisplayMode)
                    draggingItem.setDraggingFrame(contentFrame, contents: ghostImage)
                } else {
                    draggingItem.draggingFrame = anchorSpacerFrame
                }
            }
        }
        // beginDraggingSession(with:event:source:) returns a NON-optional session (only the
        // gesture-recognition variant is nullable); a `guard let` here would not compile.
        let session = spacer.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.draggingFormation = .pile
        return true
    }

    private func reportFailure(_ kind: DragOutFailureKind) {
        guard !reportedFailure else { return }
        reportedFailure = true
        onFailed?(kind)
    }

    private func prefetchFilenames(for dragged: [PhotoItem]) {
        guard let metadataLookup = fileProvider as? PhotoMetadataProvider else { return }
        for item in dragged {
            let uid = item.uid
            Task { @MainActor in
                guard let meta = try? await metadataLookup.metadata(for: uid),
                    let name = OriginalFileNaming.sanitizedOriginalName(meta.filename),
                    !name.isEmpty
                else { return }
                self.cachedFilenames[uid] = name
            }
        }
    }

    // MARK: - Type / filename helpers

    private static func promiseFileType(for item: PhotoItem) -> String {
        UTType(mimeType: item.mediaType)?.identifier ?? UTType.data.identifier
    }

    /// The synchronous promise filename. Uses the metadata-resolved original name when the async
    /// prefetch has landed; otherwise a deterministic fallback so AppKit can name the promise file.
    private func promiseFilename(for uid: PhotoUID) -> String {
        if let cached = cachedFilenames[uid] { return cached }
        let item = items[uid]
        let ext = OriginalFileNaming.resolvedExtension(
            filename: nil, mimeType: item?.mediaType, header: nil,
            fallbackMediaType: item?.mediaType, isVideo: item?.isVideo ?? false)
        return OriginalFileNaming.exportFilename(
            metadataFilename: nil, fallbackBase: "Encrypted-Memories-\(uid.nodeID)", ext: ext)
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(
        _ promiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
    ) -> String {
        let uid = (promiseProvider.userInfo as? PromisePayload)?.uid
        return promiseFilename(for: uid ?? PhotoUID(volumeID: "", nodeID: "unknown"))
    }

    nonisolated func filePromiseProvider(
        _ promiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Extract Sendable state SYNCHRONOUSLY: the AppKit objects (promiseProvider, completion
        // handler) are not Sendable and must not cross the actor hop. The payload's stager was
        // captured at provider creation, so delivery survives session replacement and teardown.
        let payload = promiseProvider.userInfo as? PromisePayload
        let completion = SendableResultCompletion(completionHandler)
        // Hop to the main actor for session state, then deliver via the stager's actor.
        Task { @MainActor in
            guard let payload else {
                completion(MetalGridDragOutController.noActiveSessionError)
                return
            }
            switch await payload.stager.awaitStaged(uid: payload.uid) {
            case .success(let stagedURL):
                do {
                    // Copy (not move): the staged file stays the session's backing store so a
                    // further receiver could still be served; the grace cleanup deletes it after
                    // the session ends. The copy runs detached OFF the main actor: a 2 GB video
                    // copy must not block the UI.
                    let destination = url
                    try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.copyItem(at: stagedURL, to: destination)
                    }.value
                    completion(nil)
                } catch {
                    completion(error)
                }
            case .failure(let failure):
                switch failure {
                case .cancelled:
                    completion(CocoaError(.userActivityConnectionUnavailable))
                case .diskSpaceInsufficient:
                    self.reportFailure(.insufficientSpace)
                    completion(CocoaError(.fileWriteOutOfSpace))
                case .writeFailed:
                    self.reportFailure(.writeFailed)
                    completion(CocoaError(.fileWriteUnknown))
                }
            }
        }
    }

    /// Boxes AppKit's non-Sendable completion handler so the single delivery result can cross the
    /// actor hop. Safe because the box is invoked exactly once, always from the main actor.
    private struct SendableResultCompletion: @unchecked Sendable {
        private let handler: (Error?) -> Void
        init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
        func callAsFunction(_ error: Error?) { handler(error) }
    }

    private static let noActiveSessionError = CocoaError(.userActivityConnectionUnavailable)

    /// Deliveries copy files on this queue; the file-promise machinery owns the threading.
    /// One queue for the controller's lifetime: AppKit requests a queue per delivery, and a
    /// fresh queue per call both allocated needlessly and reset the concurrent-copy budget per
    /// delivery instead of bounding the controller's deliveries overall.
    private let deliveryQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.name = "com.encryptedmemories.dragout.delivery"
        return queue
    }()

    func operationQueue(for promiseProvider: NSFilePromiseProvider) -> OperationQueue {
        deliveryQueue
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    /// Drag session ended. macOS resolves file promises only after this callback, so the stager
    /// must survive long enough for late `writePromiseTo` deliveries and in-flight staging of
    /// large media: UI state resets now, but the final cleanup runs after the grace delay.
    /// A newer session replaces `self.stager`, which the identity check below respects.
    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        let stager = stager
        self.stager = nil
        items.removeAll()
        cachedFilenames.removeAll()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.teardownGraceNanoseconds)
            guard let self else { return }
            if self.stager == nil || self.stager === stager {
                self.stager = nil
                self.items.removeAll()
                self.cachedFilenames.removeAll()
            }
            await stager?.finishAndCleanup()
        }
    }
}
