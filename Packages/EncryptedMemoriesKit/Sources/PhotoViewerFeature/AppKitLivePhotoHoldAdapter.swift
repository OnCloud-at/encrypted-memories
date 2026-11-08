import AppKit
import PhotoViewerCore

/// A touch-only press that cannot prevent native text, pan, or magnification recognizers.
@MainActor
final class AppKitLivePhotoHoldAdapter: NSPressGestureRecognizer, NSGestureRecognizerDelegate {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    /// The point uses the photo view's coordinates. Active selection also owns presses outside its text.
    var textOwnsPoint: (NSPoint) -> Bool = { _ in false }
    private var policy = LivePhotoHoldPolicy()
    private var holdOrigin: NSPoint?

    init() {
        super.init(target: nil, action: nil)
        target = self
        action = #selector(pressed)
        delegate = self
        name = "LivePhotoHold"
        allowedTouchTypes = .direct
        buttonMask = 0
        numberOfTouchesRequired = 1
        minimumPressDuration = LivePhotoHoldPolicy.minimumPressDuration
        // NSPress derives mouse delays from buttonMask; do not rely on superclass defaults.
        delaysPrimaryMouseButtonEvents = false
        delaysSecondaryMouseButtonEvents = false
        delaysOtherMouseButtonEvents = false
        delaysKeyEvents = false
        delaysMagnificationEvents = false
        delaysRotationEvents = false
        if #available(macOS 27.0, *) { isCancellableByScrollGesture = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func canPrevent(_ preventedGestureRecognizer: NSGestureRecognizer) -> Bool { false }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        !textOwnsPoint(gestureRecognizer.location(in: view))
    }

    @objc private func pressed() { consume(state, at: location(in: view)) }

    /// The action and injected-state tests use the same native-to-shared transition mapping.
    func consume(_ state: NSGestureRecognizer.State, at point: NSPoint) {
        if state == .changed, let origin = holdOrigin,
            hypot(point.x - origin.x, point.y - origin.y) > allowableMovement
        {
            // NSPress has no movement limit after recognition, so stop a moving hold explicitly.
            cancel(.pan)
            return
        }
        let event: LivePhotoHoldPolicy.Event
        switch state {
        case .began:
            holdOrigin = point
            event = .began
        case .changed: event = .changed
        case .ended: event = .ended
        case .cancelled: event = .cancelled
        case .failed: event = .failed
        default: event = .possible
        }
        let action = policy.consume(event, textIsSelected: textOwnsPoint(point))
        action?.deliver(start: onStart, stop: onStop)
    }

    func cancel(_ event: LivePhotoHoldPolicy.Event) {
        let action = policy.consume(event)
        action?.deliver(start: onStart, stop: onStop)
        holdOrigin = nil
        // Disabling cancels the native stream, including a press still waiting for its threshold.
        let enabled = isEnabled
        isEnabled = false
        isEnabled = enabled
    }
}
