import AppKit
import PhotoViewerCore

/// A touch-only press that coexists with native recognizers and cancels when another interaction takes over.
@MainActor
class AppKitLivePhotoHoldAdapter: NSPressGestureRecognizer, NSGestureRecognizerDelegate {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    /// Recognized text uses photo coordinates and excludes only the initial press.
    var textOwnsPoint: (NSPoint) -> Bool = { _ in false }
    var textIsSelected: () -> Bool = { false }
    private(set) var policy = LivePhotoHoldPolicy()
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
        // With no mouse buttons in the mask, NSPress derives no mouse delays; other delays default to false.
        if #available(macOS 27.0, *) { isCancellableByScrollGesture = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool { true }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        !textIsSelected() && !textOwnsPoint(gestureRecognizer.location(in: view))
    }

    @objc private func pressed() { consume(state, at: location(in: nil)) }

    /// Points are in window coordinates, independent of the image magnification.
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
        let action = policy.consume(event, textIsSelected: textIsSelected())
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
