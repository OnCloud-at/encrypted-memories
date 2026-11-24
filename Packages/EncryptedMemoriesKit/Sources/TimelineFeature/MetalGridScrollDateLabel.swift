import AppKit
import PhotosCore
import TimelineAppleAdapter
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

/// Owns the scroll date label of one Mac grid host: the shared session, the label view and the passive knob-contact
/// observer. The host forwards its content, its state and its viewport movements; every call here is cheap enough
/// for each scroll event. Visibility, timing, contact and placement rules live in TimelineCore; this type only reads
/// native geometry and draws.
@MainActor
final class MetalGridScrollDateLabelPresenter {
    /// Transparent to events, so scrolling and clicks reach the grid below. Its flipped bounds are the host's
    /// top-left coordinate space for the knob, the finger and the label.
    let overlay = FlippedOverlayView()
    /// Carries the slide away from a finger as a layer transform. The label's frame follows the knob inside this
    /// container, so the label's own frame changes never touch the slide.
    let slideView = MetalGridScrollDateLabelSlideView()
    let view = MetalGridScrollDateLabelView()
    let contactObserver = MetalGridIndicatorContactObserver()
    private let session: TimelineScrollDateLabelSession
    var controller: TimelineScrollDateLabelController { session.controller }
    var isEnabled: Bool { session.isEnabled }
    var isShown: Bool { session.isShown }
    /// Points at the trailing edge that another control covers, for example the date scrubber.
    private(set) var trailingInset: CGFloat = 0
    /// The toolbar height over the grid; the label never sits under it.
    private(set) var topInset: CGFloat = 0
    private weak var scrollView: NSScrollView?

    init(controller: TimelineScrollDateLabelController = TimelineScrollDateLabelController()) {
        session = TimelineScrollDateLabelSession(controller: controller)
        overlay.autoresizingMask = [.width, .height]
        slideView.autoresizingMask = [.width, .height]
        slideView.wantsLayer = true
        slideView.addSubview(view)
        overlay.addSubview(slideView)
        session.attach(self, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        contactObserver.onContact = { [weak self] point, began in
            self?.indicatorContact(at: point, began: began) ?? false
        }
        contactObserver.onEnded = { [weak self] in self?.controller.indicatorDragEnded() }
    }

    /// Adds the label above every other view of the host. `scrollView` supplies the native vertical scroller. The
    /// contact observer watches direct touches that AppKit hit-tests to the host or its scroller.
    func attach(to host: NSView, scrollView: NSScrollView) {
        self.scrollView = scrollView
        overlay.frame = host.bounds
        slideView.frame = overlay.bounds
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        contactObserver.attach(to: host, space: overlay, scrollView: scrollView)
        scrollersReflected()
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

    /// The scroll view moved or laid out its scrollers. Stores the one knob snapshot that the label and the contact
    /// observer share, then places the label.
    func scrollersReflected() {
        let knob = nativeKnobRect()
        if knob != contactObserver.thumbRect { contactObserver.thumbDidLayout(knob) }
        layout()
    }

    /// Places the label beside the native scroller knob. Runs only while the label shows; it measures a new month's
    /// text once and allocates nothing. The slide away from a finger is a transform on top of this frame.
    func layout() {
        guard isShown else { return }
        let size = view.labelSize
        let safeArea = overlay.safeAreaInsets
        guard let knob = contactObserver.thumbRect,
            let centerY = TimelineScrollDateLabelGeometry.centerY(
                thumbTop: knob.minY, thumbLength: knob.height, viewportTop: max(topInset, safeArea.top),
                viewportBottom: overlay.bounds.height - safeArea.bottom, labelHeight: size.height)
        else {
            overlay.alphaValue = 0  // No native knob, or no room between the toolbar and the bottom edge.
            return
        }
        overlay.alphaValue = 1
        let maxX = labelTrailingX
        let frame = overlay.backingAlignedRect(
            NSRect(x: maxX - size.width, y: centerY - size.height / 2, width: size.width, height: size.height),
            options: .alignAllEdgesNearest)
        if view.frame != frame { view.frame = frame }
    }

    /// The horizontal slide away from a finger on the knob, in points to the left.
    var dragOffset: CGFloat { -(slideView.layer?.affineTransform().tx ?? 0) }

    private func setDragOffset(_ offset: CGFloat, duration: TimeInterval?, tracking: Bool) {
        slideView.setTranslationX(-offset, duration: duration, tracking: tracking)
    }

    /// The label's usual trailing edge in the overlay: left of the indicator gap and of any covered trailing width.
    private var labelTrailingX: CGFloat {
        overlay.bounds.width - trailingInset - TimelineScrollDateLabelMotion.indicatorGap
    }

    /// The knob of the scroll view's vertical scroller in overlay coordinates, or nil while the scroller is hidden.
    private func nativeKnobRect() -> CGRect? {
        guard let scroller = scrollView?.verticalScroller, !scroller.isHidden else { return nil }
        let knob = scroller.rect(for: .knob)
        guard !knob.isEmpty else { return nil }
        return overlay.convert(knob, from: scroller)
    }

    /// A validated direct contact on the visible knob, in overlay coordinates. AppKit reports no contact size, so the
    /// radius is zero and the shared geometry uses its fallback.
    private func indicatorContact(at point: CGPoint, began: Bool) -> Bool {
        guard isEnabled, let knob = contactObserver.thumbRect else { return false }
        return controller.indicatorContact(
            atX: point.x, radius: MetalGridIndicatorContactObserver.contactRadius, normalRightX: labelTrailingX,
            thumbLeftX: knob.minX, began: began)
    }

    /// Ends the label with its host: no build, hide, contact or callback outlives it.
    func retire() {
        contactObserver.retire()
        scrollView = nil
        session.retire()
    }
}

extension MetalGridScrollDateLabelPresenter: TimelineScrollDateLabelDisplay {
    var displayedText: String? { view.text }
    func setText(_ text: String) { view.setText(text) }
    func prepareTextLayout() { _ = view.labelSize }

    func applyIndicatorOffset(of presentation: TimelineScrollDateLabelController.Presentation) {
        guard
            let slide = controller.indicatorSlide(
                for: presentation, currentOffset: dragOffset, labelHidden: view.isHidden)
        else { return }
        setDragOffset(slide.offset, duration: slide.duration, tracking: slide.tracking)
    }

    func setShown(_ shown: Bool, duration: TimeInterval?, changesVisibility: Bool) {
        view.setShown(shown, duration: duration)
    }

    func presentationDidApply() { layout() }
}

/// The container of the scroll date label that carries the slide away from a finger. It fills the overlay, so its
/// frame changes when the window resizes, and AppKit then resets its layer transform. It sets the slide's target again
/// after each frame change, so a finger that still holds the knob keeps the label beside it.
final class MetalGridScrollDateLabelSlideView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The horizontal translation that the slide moves to, in points.
    private var targetTranslationX: CGFloat = 0

    func setTranslationX(_ target: CGFloat, duration: TimeInterval?, tracking: Bool) {
        guard let layer else { return }
        targetTranslationX = target
        LayerPresentation.setTranslationX(target, on: layer, duration: duration, tracking: tracking)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        keepTranslation()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        keepTranslation()
    }

    private func keepTranslation() {
        guard let layer, layer.affineTransform().tx != targetTranslationX else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(translationX: targetTranslationX, y: 0))
        CATransaction.commit()
    }
}

/// Observes direct touches on the native scroller knob. It never recognizes: it stays possible while a finger holds
/// the knob and fails when the touch ends, so it never delays, prevents or cancels mouse events, the scroller's own
/// tracking or another recognizer. Mouse and indirect trackpad input never reach its contact path; they keep their
/// ordinary scrolling. It reads only public knob geometry and layer opacity; no private class or selector.
final class MetalGridIndicatorContactObserver: NSGestureRecognizer {
    /// AppKit reports no contact size for a direct touch. Zero lets the shared geometry use its fallback radius.
    static let contactRadius: CGFloat = 0

    /// A validated sample in the overlay's coordinates, and whether it begins the contact. Returns whether the
    /// contact holds.
    var onContact: ((CGPoint, Bool) -> Bool)?
    var onEnded: (() -> Void)?
    private weak var space: NSView?
    private weak var scrollView: NSScrollView?
    private var contact = TimelineScrollDateLabelIndicatorContact()
    /// The identity of the held touch; AppKit replaces NSTouch objects between events.
    private var touchIdentity: (any NSCopying & NSObjectProtocol)?

    /// The knob snapshot in the overlay's coordinates that the label also uses.
    var thumbRect: CGRect? { contact.thumbRect }
    /// Whether the observer holds a touch. Test seam only; production reads no such state.
    var isHoldingContactForTesting: Bool { contact.isHeld }

    init() {
        super.init(target: nil, action: nil)
        // Before macOS 27 the default is no touch type at all.
        allowedTouchTypes = .direct
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Observes the host. `space` is the overlay whose coordinates the knob, the finger and the label share.
    func attach(to host: NSView, space: NSView, scrollView: NSScrollView) {
        self.space = space
        self.scrollView = scrollView
        host.addGestureRecognizer(self)
    }

    override func canPrevent(_ preventedGestureRecognizer: NSGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: NSGestureRecognizer) -> Bool { false }

    /// A finger touched down at `point` in the overlay. Only a touch on the visible knob begins a contact.
    func contactBegan(at point: CGPoint) {
        finishContact()
        guard isEnabled, let space, let scrollView else { return }
        guard
            contact.accepts(
                at: point, radius: Self.contactRadius, viewportRightX: space.bounds.maxX,
                effectiveAlpha: scrollView.verticalScroller?.renderedKnobOpacity ?? 0)
        else { return }
        guard onContact?(point, true) == true else { return }
        contact.hold(at: point, radius: Self.contactRadius)
    }

    func contactMoved(at point: CGPoint) {
        guard contact.isHeld else { return }
        let ends = clampedEnds
        guard contact.move(to: point, radius: Self.contactRadius, atTop: ends.top, atBottom: ends.bottom) else {
            onEnded?()
            return
        }
        _ = onContact?(point, false)
    }

    /// Stores the knob snapshot after the scroll view reflects its clip. Fading does not end a hold.
    func thumbDidLayout(_ thumb: CGRect?) {
        if !contact.thumbDidLayout(thumb, clampedEnds: clampedEnds) { onEnded?() }
    }

    func finishContact() {
        touchIdentity = nil
        guard contact.end() else { return }
        onEnded?()
    }

    /// Ends observation with the host.
    func retire() {
        isEnabled = false
        onContact = nil
        onEnded = nil
        finishContact()
    }

    private var clampedEnds: (top: Bool, bottom: Bool) {
        scrollView?.clampedVerticalEnds ?? (false, false)
    }

    // MARK: Event decoding

    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        let touching = event.touches(matching: .touching, in: view)
        guard touching.count == 1, let touch = touching.first, touch.type == .direct, let space else {
            finishContact()  // A second finger is not a knob contact.
            state = .failed
            return
        }
        contactBegan(at: touch.location(in: space))
        if contact.isHeld {
            touchIdentity = touch.identity
        } else {
            state = .failed
        }
    }

    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        guard contact.isHeld, let space, let touch = heldTouch(in: event, phase: .moved) else { return }
        contactMoved(at: touch.location(in: space))
        if !contact.isHeld { state = .failed }
    }

    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event)
        finishContact()
        state = .failed
    }

    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        finishContact()
        state = .failed
    }

    override func reset() {
        super.reset()
        finishContact()
    }

    private func heldTouch(in event: NSEvent, phase: NSTouch.Phase) -> NSTouch? {
        guard let touchIdentity else { return nil }
        return event.touches(matching: phase, in: view).first { $0.identity.isEqual(touchIdentity) }
    }
}

extension NSScroller {
    /// The knob's rendered opacity including every ancestor, or 0 when the knob's layer cannot be identified. An
    /// overlay scroller keeps its view opaque and fades the knob's own layer, so the view's alpha proves nothing.
    /// The knob layer is the one sublayer whose frame equals the public knob rectangle: observed layer geometry,
    /// not a documented identity, so any other layout fails closed.
    var renderedKnobOpacity: Float {
        guard !isHidden, let knobLayer else { return 0 }
        return LayerPresentation.effectiveOpacity(of: knobLayer)
    }

    /// The single descendant of the scroller's layer whose frame in that layer equals the public knob rectangle; nil
    /// when none or several match. Runs at touch-down only.
    var knobLayer: CALayer? {
        guard let root = layer else { return nil }
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return nil }
        var matches: [CALayer] = []
        var pending = root.sublayers ?? []
        while let layer = pending.popLast() {
            if layer.convert(layer.bounds, to: root) == knob { matches.append(layer) }
            pending.append(contentsOf: layer.sublayers ?? [])
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

extension NSScrollView {
    /// Which ends of its scrollable range the clip sits at, within half a device pixel. Top is the content's top.
    var clampedVerticalEnds: (top: Bool, bottom: Bool) {
        let clip = contentView
        let minimum = -contentInsets.top
        let maximum = max(minimum, (documentView?.frame.height ?? 0) - clip.bounds.height + contentInsets.bottom)
        let ends = TimelineScrollDateLabelGeometry.clampedEnds(
            offset: clip.bounds.origin.y, range: minimum...maximum, scale: window?.backingScaleFactor ?? 1)
        // An unflipped document starts at the bottom: its origin zero is the content's bottom end.
        return documentView?.isFlipped == false ? (ends.bottom, ends.top) : ends
    }
}
