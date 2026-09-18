#if canImport(UIKit)
    import GridCore
    import PhotosCore
    import UIKit

    /// Owns Photos-style swipe selection for the timeline grid host while selection mode is active.
    ///
    /// Two recognizers start the same range gesture:
    /// - A one-finger pan that starts mostly horizontally on a photo. The scroll view's pan requires it to fail,
    ///   so a mostly vertical start still scrolls.
    /// - A press-and-hold on a photo. It yields to native drag-out on a selected photo, so dragging the selection
    ///   keeps its Apple Photos behavior. On an unselected photo the hold owns the press; the drag and context menu
    ///   interactions decline it through `ownsLongPress(on:)`.
    ///
    /// `GridSwipeSelection` owns the range and hit-test rules. This controller feeds it finger positions, applies
    /// the result to the host, plays selection haptics, and drives edge auto-scroll from a `CADisplayLink`.
    @MainActor
    final class UIKitTimelineGridSwipeSelectionController: NSObject, UIGestureRecognizerDelegate {
        private weak var host: UIKitTimelineGridHostView?
        let pan = UIPanGestureRecognizer()
        let hold = UILongPressGestureRecognizer()
        private var range: GridSwipeSelection<PhotoUID>?
        /// The latest finger position in host coordinates. Auto-scroll re-resolves it after each content move.
        private var fingerLocation: CGPoint = .zero
        private var autoScrollLink: CADisplayLink?
        private var lastAutoScrollTimestamp: CFTimeInterval?
        private let haptics = UISelectionFeedbackGenerator()

        init(host: UIKitTimelineGridHostView) {
            self.host = host
            super.init()
            pan.addTarget(self, action: #selector(handleGesture(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            hold.addTarget(self, action: #selector(handleGesture(_:)))
            // Long enough for a scroll to move first. Drag-out and the menu yield by ownership, not by timing.
            hold.minimumPressDuration = 0.35
            hold.delegate = self
        }

        var isActive: Bool { range != nil }

        func install(on scrollView: UIScrollView) {
            scrollView.addGestureRecognizer(pan)
            scrollView.addGestureRecognizer(hold)
            scrollView.panGestureRecognizer.require(toFail: pan)
            updateEnabled()
        }

        /// Recognizers run only while the host is in selection mode and can report a changed selection.
        /// Disabling them also cancels a gesture that is in flight when selection mode ends.
        func updateEnabled() {
            let enabled = host.map { $0.selectionMode && $0.onSelectionChanged != nil } ?? false
            if !enabled { cancel() }
            if pan.isEnabled != enabled { pan.isEnabled = enabled }
            if hold.isEnabled != enabled { hold.isEnabled = enabled }
        }

        /// True when a press on `item` belongs to swipe selection instead of drag-out or the context menu.
        /// A selected photo stays draggable whenever drag-out exists, as in Apple Photos.
        func ownsLongPress(on item: PhotoItem) -> Bool {
            guard let host, host.selectionMode, host.onSelectionChanged != nil else { return false }
            return host.dragOutProvider == nil || !host.selectedUIDs.contains(item.uid)
        }

        /// Ends an active gesture without a UIKit callback: the surface left its window, its tab, or its item set.
        /// Selection changes already reported stay committed.
        func cancel() {
            guard range != nil else { return }
            for recognizer in [pan, hold] where recognizer.isEnabled {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
            finish()
        }

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let host, !host.scrollView.isDecelerating, host.zoomTransaction == nil,
                host.pinchStartLevel == nil
            else { return false }
            if gestureRecognizer === pan {
                let translation = pan.translation(in: host)
                guard abs(translation.x) > abs(translation.y) else { return false }
                return host.item(at: startLocation(in: host.contentView)) != nil
            }
            guard let item = host.item(at: hold.location(in: host.contentView)) else { return false }
            return ownsLongPress(on: item)
        }

        /// A swipe selection moves neither the grid nor the zoom level, so it never runs with another gesture.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        // MARK: - Gesture

        @objc private func handleGesture(_ gesture: UIGestureRecognizer) {
            guard let host else { return }
            switch gesture.state {
            case .began:
                let anchorPoint =
                    gesture === pan ? startLocation(in: host.contentView) : gesture.location(in: host.contentView)
                begin(anchorPoint: anchorPoint, fingerLocation: gesture.location(in: host))
            case .changed:
                move(to: gesture.location(in: host))
            case .ended, .cancelled, .failed:
                finish()
            default:
                break
            }
        }

        /// The touch-down point: the pan reports its location only after its movement threshold.
        private func startLocation(in view: UIView) -> CGPoint {
            let location = pan.location(in: view)
            let translation = pan.translation(in: view)
            return CGPoint(x: location.x - translation.x, y: location.y - translation.y)
        }

        /// Starts a range at the photo under `anchorPoint` (content coordinates). `fingerLocation` is in host
        /// coordinates. The recognizers call this; hosted tests call it directly because UIKit touches cannot be
        /// synthesized there.
        func begin(anchorPoint: CGPoint, fingerLocation: CGPoint) {
            guard let host, let context = host.currentGridContext(),
                let anchor = GridSwipeSelection<PhotoUID>.index(
                    at: anchorPoint, engine: context.engine, level: context.level, width: host.bounds.width,
                    columnPhase: host.committedPhase, itemCount: host.itemUIDs.count),
                let range = GridSwipeSelection(
                    anchorIndex: anchor, orderedIDs: host.itemUIDs, selected: host.selectedUIDs)
            else { return }
            self.range = range
            self.fingerLocation = fingerLocation
            // The finger now selects. Auto-scroll moves the content offset directly, which works without scrolling.
            host.scrollView.isScrollEnabled = false
            host.scrollInputActive = true
            host.updateFeedInteractionState()
            applyRangeChange()
            resolveFinger()
            updateAutoScroll()
        }

        /// Moves the range end to the photo under `fingerLocation` (host coordinates).
        func move(to fingerLocation: CGPoint) {
            guard range != nil else { return }
            self.fingerLocation = fingerLocation
            resolveFinger()
            updateAutoScroll()
        }

        private func resolveFinger() {
            guard let host, var range, let context = host.currentGridContext() else { return }
            let contentPoint = host.contentView.convert(fingerLocation, from: host)
            guard
                let index = GridSwipeSelection<PhotoUID>.index(
                    at: contentPoint, engine: context.engine, level: context.level, width: host.bounds.width,
                    columnPhase: host.committedPhase, itemCount: host.itemUIDs.count),
                range.extend(to: index)
            else { return }
            self.range = range
            applyRangeChange()
        }

        /// Every range change ticks the selection haptic, also over photos whose state does not change. The host
        /// and the shell receive only a selection that differs.
        private func applyRangeChange() {
            haptics.selectionChanged()
            haptics.prepare()
            guard let host, let range else { return }
            let selection = range.selection
            guard selection != host.selectedUIDs else { return }
            host.selectedUIDs = selection
            host.requestRender()
            host.invalidateAccessibilityElements()
            host.onSelectionChanged?(selection)
        }

        func finish() {
            stopAutoScroll()
            range = nil
            guard let host else { return }
            host.scrollView.isScrollEnabled = true
            host.scrollInputActive = false
            host.updateFeedInteractionState()
            host.requestRender()
        }

        // MARK: - Edge auto-scroll

        private var autoScrollVelocity: CGFloat {
            guard let host else { return 0 }
            let insets = host.safeAreaInsets
            return GridSwipeAutoScrollPolicy.velocity(
                touchY: fingerLocation.y, visibleMinY: insets.top, visibleMaxY: host.bounds.height - insets.bottom)
        }

        private func updateAutoScroll() {
            guard range != nil, autoScrollVelocity != 0 else {
                stopAutoScroll()
                return
            }
            guard autoScrollLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(autoScrollTick(_:)))
            link.add(to: .main, forMode: .common)
            autoScrollLink = link
            lastAutoScrollTimestamp = nil
        }

        @objc private func autoScrollTick(_ link: CADisplayLink) {
            guard let host, range != nil else {
                stopAutoScroll()
                return
            }
            let elapsed = lastAutoScrollTimestamp.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
            lastAutoScrollTimestamp = link.timestamp
            let velocity = autoScrollVelocity
            guard velocity != 0 else {
                stopAutoScroll()
                return
            }
            let scrollView = host.scrollView
            let minimumY = -scrollView.contentInset.top
            let currentY = scrollView.contentOffset.y
            let targetY = min(max(currentY + velocity * CGFloat(max(0, elapsed)), minimumY), host.maxContentOffsetY)
            // At a content edge nothing is left to reveal. The next finger movement restarts the link if needed.
            guard abs(targetY - currentY) > 0.01 else {
                stopAutoScroll()
                return
            }
            host.isApplyingProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
            host.isApplyingProgrammaticScroll = false
            host.userHasScrolledTimeline = true
            resolveFinger()
        }

        private func stopAutoScroll() {
            autoScrollLink?.invalidate()
            autoScrollLink = nil
            lastAutoScrollTimestamp = nil
        }
    }
#endif
