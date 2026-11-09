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

        private weak var host: UIView?
        private weak var scrollView: UIKitTimelineScrollView?
        private var nativeThumbRect: CGRect?

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
                nativeThumbRect = rect.map { host.convert($0, from: scrollView) }
                layout()
            }
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
            guard let nativeThumbRect,
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
            let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            if view.bounds.size != size { view.bounds.size = size }
            if view.center != center { view.center = center }
            #if DEBUG
                notePlacementForTests()
            #endif
        }

        /// Ends the label with its host: no build, hide or callback outlives it.
        func retire() {
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

            if presentation.isVisible != isShown {
                isShown = presentation.isVisible
                if isShown { host?.bringSubviewToFront(view) }
                // Suppression, routes and stale content hide at once; shows, linger expiry and marked jumps fade.
                view.setShown(isShown, duration: presentation.fadeDuration)
                #if DEBUG
                    if isShown { showCount += 1 }
                #endif
            } else if presentation.fadeDuration == nil {
                view.setShown(isShown, duration: nil)  // Stops a running fade at its information-preserving end state.
            }
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

#endif
