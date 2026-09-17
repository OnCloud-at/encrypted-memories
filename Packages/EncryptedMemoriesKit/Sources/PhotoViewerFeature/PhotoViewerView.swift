import AVFoundation
import AVKit
import DesignSystem
import PhotoViewerCore
import PhotosCore
import SwiftUI

/// `AVPlayerView` that turns a pinch-out into the same "fly closed" dismiss the still image uses, so a playing
/// video can be pinched/swiped shut too. It only reports progress; the host's shared zoom overlay renders the
/// shrink into the exact grid cell, identical to the image path.
private final class DismissableAVPlayerView: AVPlayerView {
    var onPinchDismissBegan: () -> Void = {}
    var onPinchDismissChanged: (CGFloat) -> Void = { _ in }
    var onPinchDismissEnded: (Bool) -> Void = { _ in }
    var onPageSwipe: (ViewerPageSwipeDirection) -> Void = { _ in }

    private var dismissing = false
    private var dismissProgress: CGFloat = 0
    private var pageSwipeTracker = ViewerPageSwipeTracker()
    private weak var posterView: NSImageView?
    private var displayReadinessObservation: NSKeyValueObservation?

    func attachPoster(_ image: NSImage?) {
        displayReadinessObservation?.invalidate()
        displayReadinessObservation = nil
        updatePoster(image)
        displayReadinessObservation = observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor in self?.revealFirstFrame() }
        }
    }

    func updatePoster(_ image: NSImage?) {
        guard !isReadyForDisplay, let image, let overlay = contentOverlayView else {
            if image == nil { posterView?.removeFromSuperview() }
            return
        }
        let imageView: NSImageView
        if let posterView {
            imageView = posterView
        } else {
            imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyUpOrDown
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
        imageView.alphaValue = 1
        imageView.isHidden = false
    }

    func teardownPoster() {
        displayReadinessObservation?.invalidate()
        displayReadinessObservation = nil
        posterView?.removeFromSuperview()
    }

    private func revealFirstFrame() {
        guard let posterView, !posterView.isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            posterView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.finishPosterReveal() }
        }
    }

    private func finishPosterReveal() {
        posterView?.isHidden = true
    }

    override func magnify(with event: NSEvent) {
        // Only a pinch-OUT flies the video closed; pinch-in / anything else falls through to AVKit.
        guard dismissing || event.magnification < 0 else {
            super.magnify(with: event)
            return
        }
        switch event.phase {
        case .began:
            dismissing = true
            dismissProgress = 0
            onPinchDismissBegan()
        case .changed:
            dismissProgress = max(0, dismissProgress - event.magnification)  // outward pinch = negative
            onPinchDismissChanged(max(0, min(1, 1 - dismissProgress)))  // 1 = fullscreen, 0 = the grid cell
        case .ended, .cancelled:
            let shouldClose = event.phase == .ended && dismissProgress > 0.07  // a small/quick pinch is enough
            dismissing = false
            onPinchDismissEnded(shouldClose)
        default:
            break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let update = AppKitViewerPageSwipeAdapter.consume(event, with: &pageSwipeTracker)
        else {
            super.scrollWheel(with: event)
            return
        }

        if let direction = update.direction { onPageSwipe(direction) }
        if !update.consumesEvent { super.scrollWheel(with: event) }
    }
}

/// Native AppKit video view. SwiftUI's `VideoPlayer` crashes on this macOS (a `_AVKit_SwiftUI`
/// generic-metadata fatalError), and `AVPlayerView` is the better macOS surface anyway - native
/// floating controls, scrubbing, Picture-in-Picture.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let poster: NSImage?
    var isDismissing: Bool = false
    var onPinchDismissBegan: () -> Void = {}
    var onPinchDismissChanged: (CGFloat) -> Void = { _ in }
    var onPinchDismissEnded: (Bool) -> Void = { _ in }
    var onPageSwipe: (ViewerPageSwipeDirection) -> Void = { _ in }

    func makeNSView(context: Context) -> DismissableAVPlayerView {
        let view = DismissableAVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        view.onPinchDismissBegan = onPinchDismissBegan
        view.onPinchDismissChanged = onPinchDismissChanged
        view.onPinchDismissEnded = onPinchDismissEnded
        view.onPageSwipe = onPageSwipe
        view.attachPoster(poster)
        player.play()
        return view
    }

    func updateNSView(_ view: DismissableAVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
            view.attachPoster(poster)
        } else {
            view.updatePoster(poster)
        }
        view.onPinchDismissBegan = onPinchDismissBegan
        view.onPinchDismissChanged = onPinchDismissChanged
        view.onPinchDismissEnded = onPinchDismissEnded
        view.onPageSwipe = onPageSwipe
        // Hide the live video while the zoom overlay renders the shrink. Set layer opacity instead of
        // `alphaValue` so the mounted view remains hit-testable for a recovery pinch.
        view.layer?.opacity = isDismissing ? 0 : 1
    }

    static func dismantleNSView(_ view: DismissableAVPlayerView, coordinator: Void) {
        view.teardownPoster()
        view.player = nil
    }
}

/// An `AVPlayerLayer` without controls or chrome for the Live Photo motion clip. SwiftUI crossfades it over
/// the still image.
private struct MotionPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let v = PlayerLayerHostView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ v: PlayerLayerHostView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// Layer-backed NSView whose backing layer IS an `AVPlayerLayer`, so the motion frame fills the view and
/// resizes with it without any manual frame bookkeeping.
private final class PlayerLayerHostView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// Full-screen photo/video viewer: shows the best available image sharp (no blur) with a native progress
/// indicator while the full original downloads, then pinch-to-zoom + two-finger pan.
public struct PhotoViewerView: View {
    @State private var model: PhotoViewerModel
    private let onClose: () -> Void
    private let onPinchDismissBegan: () -> Void
    private let onPinchDismissChanged: (CGFloat) -> Void
    private let onPinchDismissEnded: (Bool) -> Void
    /// True while the shared zoom overlay renders the shrink-to-cell transition. This view hides its own
    /// background and image but stays mounted and hit-testable for the pinch gesture.
    private let isDismissing: Bool

    private let mediaTransition = ViewerMediaTransitionStyle.standard

    /// Size of the media area, used to place the Live badge at the displayed image's top-left corner.
    /// The image is aspect-fit (letterboxed), so a portrait photo in a wide window must show
    /// the badge inset to the image edge, not at the window edge.
    @State private var contentSize: CGSize = .zero

    /// Displayed photo rect after aspect-fit, magnification, and panning. The Live Photo motion overlay uses
    /// this rect so motion and still content share the same zoom and position.
    @State private var livePhotoFrame: CGRect?

    public init(
        model: PhotoViewerModel,
        onClose: @escaping () -> Void,
        onPinchDismissBegan: @escaping () -> Void = {},
        onPinchDismissChanged: @escaping (CGFloat) -> Void = { _ in },
        onPinchDismissEnded: @escaping (Bool) -> Void = { _ in },
        isDismissing: Bool = false
    ) {
        _model = State(initialValue: model)
        self.onClose = onClose
        self.onPinchDismissBegan = onPinchDismissBegan
        self.onPinchDismissChanged = onPinchDismissChanged
        self.onPinchDismissEnded = onPinchDismissEnded
        self.isDismissing = isDismissing
    }

    public var body: some View {
        ZStack {
            // Fill the window with the viewer background. Hide it during interactive dismiss so the grid shows
            // through behind the shrinking photo.
            ViewerVisualConstants.backgroundColor.ignoresSafeArea()
                .opacity(isDismissing ? 0 : 1)

            viewerBody

            loadingOverlay.opacity(isDismissing ? 0 : 1)
        }
        // The native inspector column. The toolbar Info button toggles it through the model, which also loads
        // the metadata when the inspector opens.
        .inspector(isPresented: infoPresented) {
            InfoPanelView(
                item: model.current,
                metadataLoadState: model.metadataLoadState,
                albumTitles: model.albumTitles,
                canLoadAlbumMemberships: model.canLoadAlbumMemberships,
                isLoadingAlbumMemberships: model.isLoadingAlbumMemberships,
                albumMembershipsLoadFailed: model.albumMembershipsLoadFailed,
                onRetry: { model.retryMetadata() }
            )
            .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
        }
        // Previous, Next and Close are native View menu commands with their key equivalents. While the
        // interactive dismiss runs, the viewer publishes no navigation: a paging command would change the
        // photo under the shrinking image.
        .focusedSceneValue(
            \.photoViewerNavigation,
            isDismissing
                ? nil
                : PhotoViewerNavigation(
                    canGoPrevious: model.canNavigatePrevious,
                    canGoNext: model.canNavigateNext,
                    goPrevious: { model.previousInContext() },
                    goNext: { model.nextInContext() },
                    close: onClose
                )
        )
        .onAppear {
            model.start()
        }
        .onDisappear { model.stop() }  // closing cancels in-flight work + stops playback
        .onExitCommand { onClose() }  // Esc closes the photo
    }

    private var infoPresented: Binding<Bool> {
        Binding(
            get: { model.showInfo },
            set: { if $0 != model.showInfo { model.toggleInfo() } }
        )
    }

    /// The media below the native window toolbar. The media uses its final frame from the first layout pass.
    private var viewerBody: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                contentSize = $0
            }
            // Live and burst badges stay at the image edge after aspect-fit letterboxing.
            .overlay(alignment: .topLeading) {
                if model.player == nil, model.image != nil, !isDismissing,
                    model.current.isLivePhoto || model.isLoadingBurst || model.hasBurstFilmstrip
                {
                    let inset = livePhotoBadgeImageInset(in: contentSize)
                    mediaBadges.offset(x: inset.width, y: inset.height)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.hasBurstFilmstrip, !isDismissing {
                    burstFilmstrip
                }
            }
    }

    /// Top-left inset of the displayed aspect-fit image within the content area. The Live badge follows the
    /// image corner for every aspect ratio.
    /// the badge follows the letterbox edge, not the window edge. Returns `.zero` before the image/size is known.
    private func livePhotoBadgeImageInset(in area: CGSize) -> CGSize {
        guard let img = model.image else { return .zero }
        let iw = img.size.width
        let ih = img.size.height
        guard iw > 0, ih > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / iw, area.height / ih)  // aspect-fit (matches the image view's gravity)
        return CGSize(
            width: max(0, (area.width - iw * scale) / 2),
            height: max(0, (area.height - ih * scale) / 2))
    }

    @ViewBuilder private var content: some View {
        if let player = model.player {
            PlayerView(
                player: player,  // single AVPlayer (streaming or downloaded) + pinch-out-to-dismiss
                poster: model.image,
                isDismissing: isDismissing,
                onPinchDismissBegan: onPinchDismissBegan,
                onPinchDismissChanged: onPinchDismissChanged,
                onPinchDismissEnded: onPinchDismissEnded,
                onPageSwipe: handlePageSwipe)
        } else if let image = model.image {
            // Still image, including a Live Photo key frame, with the motion clip crossfaded over it. Hovering
            // the Live badge or force-clicking the photo plays motion with sound.
            ZStack {
                ZoomableImageView(
                    image: image,  // pinch-zoom + interactive pinch-out-to-dismiss
                    itemIdentity: model.current.uid.nodeID,
                    isSharp: model.isSharp,
                    transitionStyle: mediaTransition,
                    isDismissing: isDismissing,
                    onPinchDismissBegan: onPinchDismissBegan,
                    onPinchDismissChanged: onPinchDismissChanged,
                    onPinchDismissEnded: onPinchDismissEnded,
                    onForceClick: { model.playMotion() },  // Press starts motion playback.
                    onForceClickEnded: { model.stopMotion() },  // Release stops motion and fades to still.
                    onPageSwipe: handlePageSwipe,
                    onPhotoFrameChanged: { livePhotoFrame = $0 },
                    onZoomChanged: { zoom in
                        guard zoom > 1.01 else { return }
                        model.requestOriginal(maxPixelSize: ViewerImageLoadPolicy.maxZoomedPixelSize)
                    })
                // Framed to the displayed photo rect (magnification/pan-transformed), so a zoomed-in Live Photo
                // plays its motion at the same zoom/position as the still - never an unzoomed clip on top.
                if model.current.isLivePhoto, let motion = model.motionPlayer {
                    if let pf = livePhotoFrame {
                        MotionPlayerLayerView(player: motion)
                            .frame(width: pf.width, height: pf.height)
                            .position(x: pf.midX, y: pf.midY)
                            .opacity(model.isMotionPlaying ? 1 : 0)
                            .animation(mediaTransition.opacityAnimation, value: model.isMotionPlaying)
                            .allowsHitTesting(false)
                    } else {
                        MotionPlayerLayerView(player: motion)
                            .opacity(model.isMotionPlaying ? 1 : 0)
                            .animation(mediaTransition.opacityAnimation, value: model.isMotionPlaying)
                            .allowsHitTesting(false)
                    }
                }
            }
            // "Come alive": a subtle zoom while the motion plays (and back on stop) that, together with the
            // opacity crossfade above, masks the photo-to-video-to-photo seam. Apply it to the whole ZStack so the still and
            // the motion scale as one (the viewer frame is `.clipped()`, so the tiny overflow is cropped, like
            // Apple). Kept small per the Live Photo feel.
            .scaleEffect(model.isMotionPlaying ? mediaTransition.liveMotionScale : 1.0)
            .animation(mediaTransition.scaleAnimation, value: model.isMotionPlaying)
        }
    }

    /// Live indicator at the top-left of the full view. AppKit offers no system Live badge image, so the badge is
    /// a native label on Liquid Glass. Hovering or force-clicking plays the preloaded motion clip with sound;
    /// leaving or releasing stops it.
    private var livePhotoBadge: some View {
        Label(L10n.string("viewer.live_badge"), systemImage: "livephoto")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .glassEffect(in: Capsule())
            .padding(.top, 14)
            .padding(.leading, 14)
            .onHover { hovering in
                if hovering { model.playMotion() } else { model.stopMotion() }
            }
            .accessibilityLabel(L10n.string("viewer.live_photo_a11y"))
    }

    @ViewBuilder private var mediaBadges: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.current.isLivePhoto {
                livePhotoBadge
            }
            if model.isLoadingBurst || model.hasBurstFilmstrip {
                burstBadge
            }
        }
    }

    private var burstBadge: some View {
        let position = (model.burstIndex ?? 0) + 1
        let total = max(model.burstItems.count, 1)
        return HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 12, weight: .medium))
            if model.isLoadingBurst {
                Text(L10n.string("viewer.burst_loading"))
                    .font(.system(size: 11, weight: .semibold))
            } else {
                Text(L10n.string("viewer.burst_badge \(position) \(total)"))
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffect(in: Capsule())
        .padding(.top, model.current.isLivePhoto ? 0 : 14)
        .padding(.leading, 14)
        .accessibilityLabel(Text(L10n.string("viewer.burst_filmstrip_label")))
    }

    private var burstFilmstrip: some View {
        let width = max(contentSize.width - 40, 320)
        let itemSide = burstFilmstripItemSide(panelWidth: width, itemCount: model.burstItems.count)
        let needsScroller = burstFilmstripNeedsScroller(
            panelWidth: width, itemCount: model.burstItems.count, itemSide: itemSide)
        let position = (model.burstIndex ?? 0) + 1
        let total = max(model.burstItems.count, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("viewer.burst_badge \(position) \(total)"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 2)
            BurstFilmstripView(
                items: model.burstItems,
                selectedUID: model.current.uid,
                feed: model.thumbnailFeed,
                itemSide: itemSide,
                showsHorizontalScroller: needsScroller,
                onSelect: { model.selectBurstIndex($0) }
            )
            .frame(height: itemSide + (needsScroller ? 18 : 0))
            .accessibilityLabel(Text(L10n.string("viewer.burst_filmstrip_label")))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: width)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.bottom, 16)
    }

    private func burstFilmstripItemSide(panelWidth: CGFloat, itemCount: Int) -> CGFloat {
        let count = max(itemCount, 1)
        let viewportWidth = max(panelWidth - 24, 1)  // outer VStack horizontal padding
        let sectionInset: CGFloat = 8  // NSCollectionView left + right inset
        let totalSpacing = CGFloat(max(count - 1, 0)) * 8
        let fitted = (viewportWidth - sectionInset - totalSpacing) / CGFloat(count)
        return min(112, max(58, floor(fitted)))
    }

    private func burstFilmstripNeedsScroller(panelWidth: CGFloat, itemCount: Int, itemSide: CGFloat) -> Bool {
        let count = max(itemCount, 1)
        let viewportWidth = max(panelWidth - 24, 1)
        let contentWidth = CGFloat(count) * itemSide + CGFloat(max(count - 1, 0)) * 8 + 8
        return contentWidth > viewportWidth + 0.5
    }

    /// Loading / error affordance for the media (image original or video). The cardinal rule: before
    /// a video player exists, this view may show a blocking resolver/download affordance. Once AVKit
    /// owns a player surface, AVKit also owns its native loading spinner; this layer must not stack a
    /// second round spinner over it.
    @ViewBuilder private var loadingOverlay: some View {
        if let error = model.videoState.error {
            failureCard(error)
        } else if model.videoState.isBusy && !model.videoState.hasPlayer {
            // Resolving/downloading have no player yet, so they're a centered blocking spinner.
            // Buffering/seeking use the live AVKit surface and its native spinner instead.
            busyOverlay
                .allowsHitTesting(false)
        } else if model.livePhotoReadiness == .loading {
            imageLoadingOverlay
                .allowsHitTesting(false)
        } else if model.livePhotoReadiness == .failed {
            livePhotoLoadFailureOverlay
                .allowsHitTesting(false)
        } else if model.player == nil && !model.isSharp && model.isLoadingOriginal {
            imageLoadingOverlay  // still images: percent while the original downloads
        }
    }

    /// The native unavailable state on glass. The card sits above the photo, whose colors are unknown, so it
    /// keeps a backing surface instead of drawing bare text onto the image.
    private func failureCard(_ error: VideoPlaybackError) -> some View {
        ContentUnavailableView {
            Label(L10n.string("viewer.playback_failed"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.userMessage)
        } actions: {
            if error.isRetryable {
                Button(L10n.string("action.retry")) { model.retry() }
                    .buttonStyle(.glassProminent)
            }
        }
        .fixedSize()
        .padding(24)
        .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var busyOverlay: some View {
        let isDownloading = if case .downloading = model.videoState { true } else { false }
        return progressIndicator(model.videoState.progress, isDownloading: isDownloading)
    }

    private var imageLoadingOverlay: some View {
        progressIndicator(model.originalProgress, isDownloading: true)
    }

    /// A native determinate indicator with a percentage while bytes arrive, otherwise the indeterminate spinner.
    @ViewBuilder private func progressIndicator(_ progress: Double, isDownloading: Bool) -> some View {
        if isDownloading, progress > 0.001, progress < 0.995 {
            ProgressView(value: progress) {
                EmptyView()
            } currentValueLabel: {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .progressViewStyle(.circular)
            .controlSize(.large)
            .padding(20)
            .glassEffect(in: Circle())
        } else {
            ProgressView()
                .controlSize(.large)
                .padding(20)
                .glassEffect(in: Circle())
        }
    }

    private var livePhotoLoadFailureOverlay: some View {
        Label(L10n.string("viewer.playback_failed"), systemImage: "exclamationmark.triangle")
            .labelStyle(.iconOnly)
            .font(.largeTitle)
            .foregroundStyle(.primary)
            .padding(20)
            .glassEffect(in: Circle())
    }

    private func handlePageSwipe(_ direction: ViewerPageSwipeDirection) {
        switch direction {
        case .previous: model.previousInContext()
        case .next: model.nextInContext()
        }
    }
}
