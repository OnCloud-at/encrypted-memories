/// Coalesces render invalidations into at most one render per display tick.
/// The tick remains active while presentation or visible-content work is pending.
/// Hosts provide the display link and call `completeTick` after each render attempt.
public struct GridFramePump: Equatable, Sendable {
    /// A fresh pump wants a first frame - content configured before the first tick must draw.
    private var dirty = true
    /// Whether the host surface is the active one. A fresh pump is active (the common single-surface case).
    private var active = true

    public init() {}

    /// Note that the on-screen state changed (scroll, new items, layout, arrived thumbnails).
    public mutating func invalidate() { dirty = true }

    /// Whether the host surface is currently active (its tab/window is foreground).
    public var isActive: Bool { active }

    /// Set whether the host surface is active. Reactivating re-arms one frame so the surface redraws on
    /// return; deactivating leaves `dirty` untouched (so the pending frame is drawn once the surface is
    /// active again) but immediately gates `shouldTick` to false. Returns whether the active state changed,
    /// so the host only reacts (stop the link / arm a render) on a real transition.
    @discardableResult
    public mutating func setActive(_ active: Bool) -> Bool {
        guard active != self.active else { return false }
        self.active = active
        if active { dirty = true }
        return true
    }

    /// Whether the next display tick should render: only when active AND something is dirty.
    public var shouldTick: Bool { active && dirty }

    /// Report the outcome of a tick's render. Returns whether the tick loop must keep running - never while
    /// inactive, so a host that deactivates mid-flight stops its loop on the next `completeTick`.
    @discardableResult
    public mutating func completeTick(presented: Bool, hasPendingWork: Bool) -> Bool {
        dirty = !presented || hasPendingWork
        return active && dirty
    }
}
