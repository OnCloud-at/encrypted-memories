/// Platform background-execution owner that hosts at most one Smart Search lifecycle at a time.
@MainActor
public protocol MLSmartSearchBackgroundHost: AnyObject {
    func configure(lifecycle: MLSmartSearchLifecycle)
    func detach(lifecycle: MLSmartSearchLifecycle)
}
