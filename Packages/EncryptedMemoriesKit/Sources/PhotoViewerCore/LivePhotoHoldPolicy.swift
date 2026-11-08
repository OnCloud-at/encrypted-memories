/// Shared timing and playback transitions for a stationary Live Photo hold.
public struct LivePhotoHoldPolicy {
    public static let minimumPressDuration = 0.3

    public enum Event {
        case possible, began, changed, ended, cancelled, failed
        case scroll, pan, pinch, pageChange, teardown, textSelection
    }

    public enum Action {
        case start, stop

        public func deliver(start: (() -> Void)?, stop: (() -> Void)?) {
            switch self {
            case .start: start?()
            case .stop: stop?()
            }
        }
    }

    private var active = false

    public init() {}

    public mutating func consume(_ event: Event, textIsSelected: Bool = false) -> Action? {
        switch textIsSelected ? .textSelection : event {
        case .began:
            guard !active else { return nil }
            active = true
            return .start
        case .possible, .changed:
            return nil
        case .ended, .cancelled, .failed, .scroll, .pan, .pinch, .pageChange, .teardown, .textSelection:
            guard active else { return nil }
            active = false
            return .stop
        }
    }
}
