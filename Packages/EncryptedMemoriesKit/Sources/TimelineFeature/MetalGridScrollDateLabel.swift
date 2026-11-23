import AppKit
import PhotosCore
import TimelineCore

/// The transient month and year label beside the overlay scroller of the Mac grid. Display only: it takes no clicks
/// and is not an accessibility element, so the grid's hit testing and its accessible dates stay as they are, and
/// VoiceOver announces no month changes. The glass and the label color follow the system appearance.
final class MetalGridScrollDateLabelView: NSView {
    private let glass = NSGlassEffectView()
    /// The glass sizes its content view to itself, so the text sits inside a padded container.
    private let content = NSView()
    private let label = NSTextField(labelWithString: "")
    /// The same padding as the date scrubber's pill. Measured once per text change, not per scroll event.
    private var textSize = TimelineScrollDateLabelTextSizeCache(
        horizontalPadding: TimelineDateScrubber.pillHorizontalPadding,
        verticalPadding: TimelineDateScrubber.pillVerticalPadding)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The same type as the scrubber's date pill.
        label.font = .systemFont(ofSize: TimelineDateScrubber.pillFontSize, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping
        label.setAccessibilityElement(false)
        glass.style = .regular
        content.addSubview(label)
        glass.contentView = content
        addSubview(glass)
        setAccessibilityElement(false)
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    var text: String? { label.stringValue.isEmpty ? nil : label.stringValue }

    func setText(_ text: String) {
        guard label.stringValue != text else { return }
        label.stringValue = text
        textSize.invalidate()
        needsLayout = true
    }

    /// The label size for the current text.
    var labelSize: CGSize {
        textSize.fittingSize { label.intrinsicContentSize }
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = bounds.height / 2
        content.frame = glass.bounds
        // The padded rectangle is the text's alignment rectangle; the field's native frame also includes its insets.
        label.frame = label.frame(forAlignmentRect: textSize.contentFrame(in: content.bounds))
    }

    /// Fades the label in or out over `duration`. Without a duration (Reduce Motion, suppression, a route) it changes
    /// at once and stops a running fade.
    func setShown(_ shown: Bool, duration: TimeInterval?) {
        if shown { isHidden = false }
        let target: CGFloat = shown ? 1 : 0
        guard let duration else {
            layer?.removeAllAnimations()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                alphaValue = target
            }
            isHidden = !shown
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
            animator().alphaValue = target
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !shown, self.alphaValue == 0 else { return }
                self.isHidden = true
            }
        }
    }
}

/// Owns the scroll date label of one Mac grid host: the shared session and the label view. The host forwards its
/// content, its state and its viewport movements; every call here is cheap enough for each scroll event. Visibility,
/// timing, transition and placement rules live in TimelineCore; this type only reads native geometry and draws.
@MainActor
final class MetalGridScrollDateLabelPresenter {
    /// Transparent to events, so scrolling and clicks reach the grid below. Its flipped bounds are the host's
    /// top-left coordinate space for the knob and the label.
    let overlay = FlippedOverlayView()
    let view = MetalGridScrollDateLabelView()
    private let session: TimelineScrollDateLabelSession
    var controller: TimelineScrollDateLabelController { session.controller }
    var isEnabled: Bool { session.isEnabled }
    var isShown: Bool { session.isShown }
    /// Points at the trailing edge that another control reserves, for example the date scrubber.
    private(set) var trailingInset: CGFloat = 0
    /// The toolbar height over the grid; the label never sits under it.
    private(set) var topInset: CGFloat = 0
    private weak var scrollView: NSScrollView?

    init(controller: TimelineScrollDateLabelController = TimelineScrollDateLabelController()) {
        session = TimelineScrollDateLabelSession(controller: controller)
        overlay.autoresizingMask = [.width, .height]
        overlay.addSubview(view)
        session.attach(self, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Adds the label above every other view of the host. `scrollView` supplies the native vertical scroller.
    func attach(to host: NSView, scrollView: NSScrollView) {
        self.scrollView = scrollView
        overlay.frame = host.bounds
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    func setEnabled(_ enabled: Bool) { session.setEnabled(enabled) }

    func setReduceMotion(_ reduce: Bool) { session.setReduceMotion(reduce) }

    func setTrailingInset(_ inset: CGFloat) {
        guard inset != trailingInset else { return }
        trailingInset = inset
        layout()
    }

    func setTopInset(_ inset: CGFloat) {
        guard inset != topInset else { return }
        topInset = inset
        layout()
    }

    /// The host shows new items. `replacesList` marks another list (route, filter, search result); otherwise it is a
    /// refresh of the same list.
    func contentChanged(_ items: [PhotoItem], replacesList: Bool) {
        session.contentChanged(items, replacesList: replacesList)
    }

    func updateHost(_ state: TimelineScrollDateLabelHostState) { controller.updateHost(state) }

    func viewportMoved(_ movement: TimelineScrollDateLabelMovement, offsetY: CGFloat) {
        session.viewportMoved(movement, offsetY: Double(offsetY))
    }

    /// A photo opens over the grid: the label leaves at once.
    func hideForRoute() { controller.hide() }

    func setAnchor(flatIndex: Int?) { session.setAnchor(flatIndex: flatIndex) }

    /// Places the label beside the native scroller knob. Runs only while the label shows; it measures a new month's
    /// text once and allocates nothing.
    func layout() {
        guard isShown else { return }
        let size = view.labelSize
        let safeArea = overlay.safeAreaInsets
        guard let knob = nativeKnobRect(),
            let centerY = TimelineScrollDateLabelGeometry.centerY(
                thumbTop: knob.minY, thumbLength: knob.height, viewportTop: max(topInset, safeArea.top),
                viewportBottom: overlay.bounds.height - safeArea.bottom, labelHeight: size.height)
        else {
            overlay.alphaValue = 0  // No native knob, or no room between the toolbar and the bottom edge.
            return
        }
        overlay.alphaValue = 1
        let maxX = overlay.bounds.width - trailingInset - TimelineScrollDateLabelMotion.indicatorGap
        let frame = overlay.backingAlignedRect(
            NSRect(x: maxX - size.width, y: centerY - size.height / 2, width: size.width, height: size.height),
            options: .alignAllEdgesNearest)
        if view.frame != frame { view.frame = frame }
    }

    /// The knob of the scroll view's vertical scroller in overlay coordinates, or nil while the scroller is hidden.
    private func nativeKnobRect() -> CGRect? {
        guard let scroller = scrollView?.verticalScroller, !scroller.isHidden else { return nil }
        let knob = scroller.rect(for: .knob)
        guard !knob.isEmpty else { return nil }
        return overlay.convert(knob, from: scroller)
    }

    /// Ends the label with its host: no build, hide or callback outlives it.
    func retire() {
        scrollView = nil
        session.retire()
    }
}

extension MetalGridScrollDateLabelPresenter: TimelineScrollDateLabelDisplay {
    var displayedText: String? { view.text }
    func setText(_ text: String) { view.setText(text) }
    func prepareTextLayout() { _ = view.labelSize }

    func setShown(_ shown: Bool, duration: TimeInterval?, changesVisibility: Bool) {
        view.setShown(shown, duration: duration)
    }

    func presentationDidApply() { layout() }
}
