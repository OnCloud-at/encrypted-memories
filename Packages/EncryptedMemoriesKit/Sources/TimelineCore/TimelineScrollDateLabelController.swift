import Foundation
import PhotosCore

/// The time source of the scroll date label. Production uses the monotonic system uptime; tests inject a manual
/// clock. `sleep(until:)` waits for an absolute instant, so a late registration cannot move the deadline.
public struct TimelineScrollDateLabelClock: Sendable {
    public let now: @Sendable () -> TimeInterval
    public let sleep: @Sendable (_ until: TimeInterval) async throws -> Void

    public init(
        now: @escaping @Sendable () -> TimeInterval,
        sleep: @escaping @Sendable (_ until: TimeInterval) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = TimelineScrollDateLabelClock(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { deadline in
            let delay = deadline - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        })
}

/// Shared state of one grid's scroll date label. The host forwards its content and viewport events and draws
/// `presentation`; this type owns the visibility policy, the month index build, the month lookup and the one pending
/// hide.
///
/// Scroll events only update numbers. The text is looked up only when the anchor photo leaves the current month.
/// At most one hide task waits at a time; a new deadline moves without a new task.
@MainActor
public final class TimelineScrollDateLabelController {
    public struct Presentation: Equatable, Sendable {
        public let isVisible: Bool
        /// The month and year of the anchor photo. It stays set while the label fades out.
        public let text: String?

        public static let hidden = Presentation(isVisible: false, text: nil)
    }

    /// Called with the new presentation whenever it changes.
    public var onChange: ((Presentation) -> Void)?
    /// Called when a newly built index is installed, so a host can prepare its text layout outside a scroll.
    public var onIndexInstalled: ((TimelineScrollDateIndex) -> Void)?
    public private(set) var presentation: Presentation = .hidden
    public private(set) var policy: TimelineScrollDateLabelPolicy
    public private(set) var index: TimelineScrollDateIndex?

    /// True after `retire()`: the host is gone.
    public private(set) var isRetired = false
    /// False when the last change must take effect at once: a suppression, a route change or stale content. The
    /// normal hide after the linger time, a marked navigation jump, and every show animate.
    public private(set) var animatesLastChange = true

    private let clock: TimelineScrollDateLabelClock
    private let scheduler: TimelineScrollDateIndexScheduler
    private var classifier = TimelineScrollDateLabelInputClassifier()
    private var anchorFlatIndex: Int?
    private var month: TimelineScrollDateIndex.Month?
    private var hideTask: Task<Void, Never>?

    public init(
        clock: TimelineScrollDateLabelClock = .system, tuning: TimelineScrollDateLabelPolicy.Tuning = .standard,
        build: @escaping TimelineScrollDateIndexScheduler.Builder = TimelineScrollDateIndexScheduler.detachedBuild
    ) {
        self.clock = clock
        policy = TimelineScrollDateLabelPolicy(tuning: tuning)
        scheduler = TimelineScrollDateIndexScheduler(build: build)
        scheduler.onIndex = { [weak self] index in
            guard let self, !isRetired else { return }
            setIndex(index)
            if let index { onIndexInstalled?(index) }
        }
    }

    /// The host shows new items.
    ///
    /// - A refresh of the same list (`replacesList == false`, for example new photos during a library update) keeps the
    ///   current markers until the new ones are built, so a refresh during a scroll neither hides nor restarts the
    ///   label. For one build period an anchor below a newly inserted photo can name the month of its old position.
    /// - A replaced list (`replacesList == true`: another account, filter, search result or order) hides the label and
    ///   drops the old markers at once, so no month of the old list appears.
    public func updateContent(_ items: [PhotoItem], replacesList: Bool) {
        guard !isRetired else { return }
        if replacesList {
            // The running build is for the old list; it must not install its markers for the new one.
            scheduler.cancel()
            setIndex(nil)
        }
        scheduler.update(items: items)
    }

    /// The surface stopped showing dates (disabled, loading or failed): no markers and no label.
    public func clearContent() {
        scheduler.cancel()
        setIndex(nil)
    }

    /// Installs the markers of the current content, or nil while they are not ready. A missing index hides the label,
    /// so a loading or replaced list never shows a stale month.
    public func setIndex(_ newIndex: TimelineScrollDateIndex?) {
        guard newIndex != index else { return }
        index = newIndex
        month = nil
        if newIndex == nil { policy.hide() }
        publish(animated: newIndex != nil)
    }

    /// The flat index of the photo that anchors the visible area: the first photo row below the top bar.
    public func setAnchor(flatIndex: Int?) {
        anchorFlatIndex = flatIndex
        guard policy.isVisible else { return }  // The text is resolved when the label shows.
        if let flatIndex, let month, month.range.contains(flatIndex) { return }
        publish()
    }

    /// One viewport movement as the host observed it. The shared classifier decides whether it counts as user
    /// scrolling.
    public func viewportMoved(_ movement: TimelineScrollDateLabelMovement, offsetY: Double) {
        guard !isRetired else { return }
        if classifier.isUserMovement(movement, at: clock.now()) {
            userMoved(offsetY: offsetY)
        } else {
            nonUserMoved(isJump: movement.isJump && !movement.isLayout)
        }
    }

    /// Applies the host state: a suppressing state hides the label at once, the others let it show again on the next
    /// brisk scroll.
    public func updateHost(_ state: TimelineScrollDateLabelHostState) {
        if state.suppressesLabel { suppress() } else { resume() }
    }

    /// A viewport movement that the user drives.
    public func userMoved(offsetY: Double) {
        guard !isRetired else { return }
        let wasVisible = policy.isVisible
        policy.userMoved(offsetY: offsetY, at: clock.now())
        if policy.isVisible != wasVisible { publish() }
        scheduleHideIfNeeded()
    }

    /// A movement without user input. A marked navigation jump cancels the linger and starts the fast fade-out.
    /// Layout, resize and content-driven adjustments only reset the speed sample.
    public func nonUserMoved(isJump: Bool = false) {
        policy.nonUserMoved(isJump: isJump)
        if isJump {
            cancelHide()
            publish()
        }
    }

    /// Hides the label at once, for example when a photo opens over the grid. A new brisk scroll can show it again.
    public func hide() {
        cancelHide()
        policy.hide()
        publish(animated: false)
    }

    /// Hides the label at once and cancels its pending hide: pinch, route change, inactive surface.
    public func suppress() {
        guard !policy.isSuppressed else { return }
        policy.suppress()
        cancelHide()
        publish(animated: false)
    }

    public func resume() {
        guard policy.isSuppressed, !isRetired else { return }
        policy.resume()
    }

    /// Ends this label for good: the host is gone. No later callback reaches the host.
    public func retire() {
        isRetired = true
        scheduler.cancel()
        policy.suppress()
        cancelHide()
        onChange = nil
        presentation = .hidden
    }

    private func publish(animated: Bool = true) {
        let visible = policy.isVisible && !policy.isSuppressed
        var text = presentation.text
        if visible {
            if let anchorFlatIndex, let resolved = index?.month(containing: anchorFlatIndex) {
                month = resolved
                text = resolved.text
            } else {
                // The anchor lies outside the current markers, for example while the markers of a replaced list
                // build. The last month stays, so the label neither flickers nor disappears.
                month = nil
            }
        }
        if index == nil { text = nil }
        let next = Presentation(isVisible: visible && text != nil, text: text)
        // An immediate hide also reaches the host when the label is already fading out, so the fade stops at once.
        guard next != presentation || (!animated && !next.isVisible) else { return }
        presentation = next
        animatesLastChange = animated
        onChange?(next)
    }

    private func scheduleHideIfNeeded() {
        guard hideTask == nil, policy.isVisible, policy.hideDeadline != nil else { return }
        let clock = clock
        hideTask = Task { [weak self] in
            while let deadline = self?.policy.hideDeadline {
                do {
                    try await clock.sleep(deadline)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                if policy.tick(at: clock.now()) {
                    hideTask = nil
                    publish()
                    return
                }
                guard policy.isVisible else { break }  // Another path hid it; loop ends on a nil deadline.
            }
            self?.hideTask = nil
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }
}
