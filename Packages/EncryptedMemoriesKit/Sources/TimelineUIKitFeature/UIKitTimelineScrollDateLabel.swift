#if canImport(UIKit)
    import PhotosCore
    import TimelineCore
    import UIKit

    #if DEBUG
        /// UI tests read the label state through one accessibility element. Only a UI test that passes
        /// `launchArgument` turns it on; the label stays hidden from VoiceOver in every other build and launch.
        @MainActor
        public enum UIKitTimelineScrollDateLabelTesting {
            public nonisolated static let launchArgument = "-EncryptedMemoriesScrollDateLabelProbe"
            public static var exposesLabel = false
        }
    #endif

    /// Owns the scroll date label of one grid host: the shared controller and the label view. The host forwards its
    /// content, its state and its viewport movements; every call here is cheap enough for each scroll event.
    @MainActor
    final class UIKitTimelineScrollDateLabelPresenter {
        let view = UIKitTimelineScrollDateLabelView()
        private let session: TimelineScrollDateLabelSession
        var controller: TimelineScrollDateLabelController { session.controller }
        var isEnabled: Bool { session.isEnabled }
        /// Viewport bands the label must not cover (fold, camera), sorted by their top edge.
        private var avoidedBands: [ClosedRange<CGFloat>] = []
        private var isShown = false
        private var appliedFadeDuration: TimeInterval?
        let indicatorDragObserver = UIKitTimelineIndicatorDragObserver()
        private weak var host: UIView?
        private weak var scrollView: UIKitTimelineScrollView?

        init(controller: TimelineScrollDateLabelController = TimelineScrollDateLabelController()) {
            session = TimelineScrollDateLabelSession(controller: controller)
            controller.onChange = { [weak self] presentation in self?.apply(presentation) }
            controller.onIndexInstalled = { [weak self] index in self?.prepareText(for: index) }
            controller.reduceMotion = UIAccessibility.isReduceMotionEnabled
        }

        /// Adds the label above the grid.
        func attach(to host: UIView, scrollView: UIKitTimelineScrollView) {
            self.host = host
            self.scrollView = scrollView
            host.addSubview(view)
            scrollView.onVerticalIndicatorLayout = { [weak self, weak host, weak scrollView] rect in
                guard let self, let host, let scrollView else { return }
                indicatorDragObserver.thumbDidLayout(rect.map { host.convert($0, from: scrollView) })
                layout()
            }
            indicatorDragObserver.attach(to: host, scrollView: scrollView)
            indicatorDragObserver.onContact = { [weak self] point, radius, began in
                self?.indicatorContact(at: point, radius: radius, began: began) ?? false
            }
            indicatorDragObserver.onEnded = { [weak self] in self?.controller.indicatorDragEnded() }
        }

        func setEnabled(_ enabled: Bool) { session.setEnabled(enabled) }

        func setReduceMotion(_ reduce: Bool) { controller.reduceMotion = reduce }

        /// The host shows new items. `replacesList` marks another list (account, filter, search result); otherwise it is
        /// a refresh of the same list.
        func contentChanged(_ newItems: [PhotoItem], replacesList: Bool) {
            session.contentChanged(newItems, replacesList: replacesList)
        }

        func updateHost(_ state: TimelineScrollDateLabelHostState) {
            controller.updateHost(state)
        }

        func viewportMoved(_ movement: TimelineScrollDateLabelMovement, offsetY: CGFloat) {
            guard isEnabled else { return }
            controller.viewportMoved(movement, offsetY: Double(offsetY))
        }

        private func indicatorContact(at point: CGPoint, radius: CGFloat, began: Bool) -> Bool {
            guard isEnabled, let host, let nativeThumbRect = indicatorDragObserver.thumbRect else { return false }
            let offset = TimelineScrollDateLabelGeometry.indicatorDragOffset(
                normalRightX: labelTrailingX(in: host), thumbLeftX: nativeThumbRect.minX,
                contactX: point.x, contactRadius: radius)
            if began {
                controller.indicatorDragBegan(offset: offset, radius: radius)
            } else {
                controller.indicatorDragMoved(offset: offset, radius: radius)
            }
            return controller.policy.isIndicatorDragging
        }

        private func labelTrailingX(in host: UIView) -> CGFloat {
            host.bounds.width - host.safeAreaInsets.right - TimelineScrollDateLabelMotion.indicatorGap
        }

        /// A photo opens over the grid: the label leaves at once.
        func hideForRoute() { controller.hide() }

        func setAnchor(flatIndex: Int?) {
            guard isEnabled else { return }
            controller.setAnchor(flatIndex: flatIndex)
        }

        func setAvoidedBands(_ bands: [ClosedRange<CGFloat>]) {
            guard bands != avoidedBands else { return }
            avoidedBands = bands
            layout()
        }

        /// Places the label beside the scroll indicator. Runs only while the label shows.
        func layout() {
            guard isShown, let host else { return }
            let size = view.fittingSize
            guard let nativeThumbRect = indicatorDragObserver.thumbRect,
                let centerY = TimelineScrollDateLabelGeometry.centerY(
                    thumbTop: nativeThumbRect.minY, thumbLength: nativeThumbRect.height,
                    viewportTop: host.safeAreaInsets.top,
                    viewportBottom: host.bounds.height - host.safeAreaInsets.bottom,
                    labelHeight: size.height, avoiding: avoidedBands)
            else {
                view.alpha = 0  // No native thumb geometry or no space outside the reserved regions.
                return
            }
            view.alpha = 1
            let origin = CGPoint(
                x: (labelTrailingX(in: host) - size.width).rounded(), y: centerY - size.height / 2)
            // Setting frame while transformed would fold the horizontal slide into the next viewport position.
            let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            if view.bounds.size != size { view.bounds.size = size }
            if view.center != center { view.center = center }
            #if DEBUG
                notePlacementForTests()
            #endif
        }

        /// Ends the label with its host: no build, hide or callback outlives it.
        func retire() {
            indicatorDragObserver.isEnabled = false
            scrollView?.onVerticalIndicatorLayout = nil
            controller.retire()
        }

        /// Shapes the first month once, so the first brisk scroll does not pay for font and text layout.
        private func prepareText(for index: TimelineScrollDateIndex) {
            guard view.text == nil, let first = index.month(containing: 0)?.text else { return }
            view.setText(first)
            _ = view.fittingSize
            view.layoutIfNeeded()
        }

        private func apply(_ presentation: TimelineScrollDateLabelController.Presentation) {
            if let text = presentation.text { view.setText(text) }
            let targetOffset = presentation.indicatorOffset
            if targetOffset != -view.transform.tx || presentation.slideDuration == nil {
                // A hidden label fades in beside the contact; visible target changes use the current presentation.
                view.setDragOffset(
                    targetOffset, duration: !view.isHidden ? presentation.slideDuration : nil,
                    tracking: controller.policy.isIndicatorDragging && !controller.reduceMotion && !view.isHidden)
            }
            if presentation.isVisible != isShown {
                isShown = presentation.isVisible
                if isShown { host?.bringSubviewToFront(view) }
                // Suppression, routes and stale content hide at once; shows, linger expiry and marked jumps fade.
                view.setShown(isShown, duration: presentation.fadeDuration)
                #if DEBUG
                    if isShown { showCount += 1 }
                #endif
            } else if presentation.fadeDuration != appliedFadeDuration {
                view.setShown(isShown, duration: presentation.fadeDuration)
            }
            appliedFadeDuration = presentation.fadeDuration
            layout()  // A new month can change the width.
            #if DEBUG
                updateTestElement()
            #endif
        }

        #if DEBUG
            private var showCount = 0
            private var placedCount = 0
            /// The label state for UI tests: its text as the label, and "<visible|hidden> <shows> <placed>" as the value.
            /// `shows` counts appearances, `placed` counts appearances that were laid out opaque inside the host.
            /// The element stays in the tree, so a test never races the fade.
            private(set) lazy var testElement: UIAccessibilityElement = {
                let element = UIAccessibilityElement(accessibilityContainer: host as Any)
                element.accessibilityIdentifier = "timeline.scrollDateLabel"
                element.accessibilityTraits = .staticText
                element.accessibilityValue = "hidden 0 0"
                return element
            }()

            private func notePlacementForTests() {
                guard UIKitTimelineScrollDateLabelTesting.exposesLabel, placedCount < showCount, let host else {
                    return
                }
                guard view.alpha == 1, !view.isHidden, host.bounds.contains(view.frame) else { return }
                placedCount = showCount
                updateTestElement()
            }

            private func updateTestElement() {
                guard UIKitTimelineScrollDateLabelTesting.exposesLabel, let host else { return }
                testElement.accessibilityLabel = view.text
                testElement.accessibilityValue = "\(isShown ? "visible" : "hidden") \(showCount) \(placedCount)"
                if isShown { testElement.accessibilityFrameInContainerSpace = view.frame }
                (host as? UIKitTimelineGridHostView)?.invalidateAccessibilityElements()
            }
        #endif
    }
    /// Observes touches without cancelling, delaying or preventing native gestures. UIKit exposes no indicator-drag
    /// flag. A direct contact on the actual native thumb starts immediately, before viewport movement.
    /// A thumb grab can use the content pan while UIKit still reports momentum; those states cannot veto it.
    /// Pointer/trackpad touches stay with normal scrolling. No private recognizer or subview class is inspected.
    final class UIKitTimelineIndicatorDragObserver: UIGestureRecognizer {
        var onContact: ((CGPoint, CGFloat, Bool) -> Bool)?
        var onEnded: (() -> Void)?
        private weak var scrollView: UIKitTimelineScrollView?
        private var contact: (y: CGFloat, radius: CGFloat)?
        private(set) var thumbRect: CGRect?

        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        func attach(to host: UIView, scrollView: UIKitTimelineScrollView) {
            self.scrollView = scrollView
            host.addGestureRecognizer(self)
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        /// Uses the reported direct-contact radius, not an invented native thumb width or hit target.
        func contactBegan(at point: CGPoint, radius: CGFloat) {
            finishContact()
            guard let host = view, let scrollView, scrollView.showsVerticalScrollIndicator,
                !scrollView.isScrollAnimating, let thumb = thumbRect
            else { return }
            guard
                TimelineScrollDateLabelGeometry.acceptsIndicatorContact(
                    at: point, radius: radius, thumb: thumb, viewportRightX: host.bounds.maxX,
                    effectiveAlpha: scrollView.verticalIndicatorEffectiveAlpha)
            else { return }
            guard onContact?(point, radius, true) == true else { return }
            contact = (point.y, radius)
            state = .began
        }

        private var clampedEnds: (top: Bool, bottom: Bool) {
            scrollView?.clampedVerticalEnds ?? (false, false)
        }

        func contactMoved(at point: CGPoint, radius: CGFloat) {
            guard let previous = contact else { return }
            defer { state = contact != nil ? .changed : .cancelled }
            let ends = clampedEnds
            guard
                TimelineScrollDateLabelGeometry.continuesIndicatorContactAfterMove(
                    at: point.y, previousY: previous.y, radius: radius, thumb: thumbRect ?? .zero,
                    atTop: ends.top, atBottom: ends.bottom)
            else {
                finishContact()
                return
            }
            contact = (point.y, radius)
            _ = onContact?(point, radius, false)
        }

        /// Stores the one host-space geometry snapshot for presentation and contact. Fading does not end a hold.
        func thumbDidLayout(_ thumb: CGRect?) {
            let previous = thumbRect
            thumbRect = thumb
            guard let contact else { return }
            let ends = clampedEnds
            guard
                TimelineScrollDateLabelGeometry.continuesIndicatorContactAfterLayout(
                    at: contact.y, radius: contact.radius, thumb: thumb ?? .zero, previousThumb: previous ?? .zero,
                    atTop: ends.top, atBottom: ends.bottom)
            else {
                finishContact()
                state = .cancelled
                return
            }
        }

        func finishContact() {
            guard contact != nil else { return }
            contact = nil
            onEnded?()
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            guard event.allTouches?.count == 1, let touch = touches.first, touch.type == .direct else {
                let wasDragging = contact != nil
                finishContact()
                state = wasDragging ? .cancelled : .failed
                return
            }
            contactBegan(at: touch.location(in: view), radius: touch.majorRadius + touch.majorRadiusTolerance)
            if contact == nil { state = .failed }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesMoved(touches, with: event)
            if contact != nil, let touch = touches.first {
                contactMoved(at: touch.location(in: view), radius: touch.majorRadius + touch.majorRadiusTolerance)
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesEnded(touches, with: event)
            let wasDragging = contact != nil
            finishContact()
            state = wasDragging ? .ended : .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesCancelled(touches, with: event)
            let wasDragging = contact != nil
            finishContact()
            state = wasDragging ? .cancelled : .failed
        }

        override func reset() {
            super.reset()
            finishContact()
        }
    }
#endif
