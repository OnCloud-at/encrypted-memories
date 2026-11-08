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

    /// The transient month and year label beside the native vertical scroll indicator. Display only: it takes no
    /// touches and is not an accessibility element, so the grid's hit testing and its accessible dates stay as they
    /// are, and VoiceOver announces no month changes.
    final class UIKitTimelineScrollDateLabelView: UIView {
        private let glass = UIVisualEffectView(effect: nil)
        /// One material for every show. A new effect object per show cost 5 to 7 ms per show and hide; the reused one
        /// 2 to 3 ms (iPhone 17 simulator, Debug).
        private let glassEffect = UIGlassEffect(style: .regular)
        private let label = UILabel()
        private static let horizontalPadding: CGFloat = 12
        private static let verticalPadding: CGFloat = 6
        /// The measured size for the current text and Dynamic Type size; measured once per change, not per scroll event.
        private var cachedSize: CGSize?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            glass.cornerConfiguration = .capsule()
            glass.isUserInteractionEnabled = false
            label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
                for: .systemFont(ofSize: 15, weight: .semibold), maximumPointSize: 22)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .label
            label.alpha = 0
            label.numberOfLines = 1
            addSubview(glass)
            glass.contentView.addSubview(label)
            isHidden = true
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
                (view: UIKitTimelineScrollDateLabelView, _: UITraitCollection) in
                view.cachedSize = nil
                view.setNeedsLayout()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        var text: String? { label.text }

        func setText(_ text: String) {
            guard label.text != text else { return }
            label.text = text
            cachedSize = nil
            setNeedsLayout()
        }

        /// The label size for the current text and Dynamic Type size.
        var fittingSize: CGSize {
            if let cachedSize { return cachedSize }
            let size = label.intrinsicContentSize
            let fitting = CGSize(
                width: ceil(size.width) + 2 * Self.horizontalPadding,
                height: ceil(size.height) + 2 * Self.verticalPadding)
            cachedSize = fitting
            return fitting
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            glass.frame = bounds
            label.frame = bounds.insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding)
        }

        /// Fades the glass in or out. Glass materializes by animating its effect, not the view's alpha. Reduce Motion
        /// shows and hides at once.
        func setShown(_ shown: Bool, animated: Bool) {
            let changes = { [self] in
                glass.effect = shown ? glassEffect : nil
                label.alpha = shown ? 1 : 0
            }
            if shown { isHidden = false }
            guard animated else {
                for layer in [layer, glass.layer, label.layer] { layer.removeAllAnimations() }
                UIView.performWithoutAnimation(changes)
                isHidden = !shown
                return
            }
            let timing = shown ? TimelineScrollDateLabelMotion.fadeIn : TimelineScrollDateLabelMotion.fadeOut
            UIView.animate(
                withDuration: timing, delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, shown ? .curveEaseOut : .curveEaseIn],
                animations: changes
            ) { [weak self] finished in
                guard let self, finished, !shown, self.label.alpha == 0 else { return }
                self.isHidden = true
            }
        }
    }

    /// Owns the scroll date label of one grid host: the shared controller and the label view. The host forwards its
    /// content, its state and its viewport movements; every call here is cheap enough for each scroll event.
    @MainActor
    final class UIKitTimelineScrollDateLabelPresenter {
        let view = UIKitTimelineScrollDateLabelView()
        let controller: TimelineScrollDateLabelController
        private(set) var isEnabled = false
        private var reduceMotion = UIAccessibility.isReduceMotionEnabled
        private var items: [PhotoItem] = []
        /// Viewport bands the label must not cover (fold, camera), sorted by their top edge.
        private var avoidedBands: [ClosedRange<CGFloat>] = []
        private var isShown = false
        private weak var host: UIView?
        private weak var scrollView: UIScrollView?

        init(controller: TimelineScrollDateLabelController = TimelineScrollDateLabelController()) {
            self.controller = controller
            controller.onChange = { [weak self] presentation in self?.apply(presentation) }
            controller.onIndexInstalled = { [weak self] index in self?.prepareText(for: index) }
        }

        /// Adds the label above the grid.
        func attach(to host: UIView, scrollView: UIScrollView) {
            self.host = host
            self.scrollView = scrollView
            host.addSubview(view)
        }

        func setEnabled(_ enabled: Bool) {
            guard enabled != isEnabled else { return }
            isEnabled = enabled
            if enabled {
                controller.updateContent(items, replacesList: true)
            } else {
                controller.clearContent()
            }
        }

        func setReduceMotion(_ reduce: Bool) { reduceMotion = reduce }

        /// The host shows new items. `replacesList` marks another list (account, filter, search result); otherwise it is
        /// a refresh of the same list.
        func contentChanged(_ newItems: [PhotoItem], replacesList: Bool) {
            items = newItems
            guard isEnabled else { return }
            controller.updateContent(newItems, replacesList: replacesList)
        }

        func updateHost(_ state: TimelineScrollDateLabelHostState) {
            controller.updateHost(state)
        }

        func viewportMoved(_ movement: TimelineScrollDateLabelMovement, offsetY: CGFloat) {
            guard isEnabled else { return }
            controller.viewportMoved(movement, offsetY: Double(offsetY))
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
            guard isShown, let host, let scrollView else { return }
            let size = view.fittingSize
            // The native thumb runs inside the indicator insets plus, by default, the scroll view's safe area.
            var indicator = scrollView.verticalScrollIndicatorInsets
            if scrollView.automaticallyAdjustsScrollIndicatorInsets {
                indicator.top += scrollView.safeAreaInsets.top
                indicator.bottom += scrollView.safeAreaInsets.bottom
            }
            let minOffset = -scrollView.contentInset.top
            let maxOffset = max(
                minOffset, scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height)
            guard
                let centerY = TimelineScrollDateLabelGeometry.centerY(
                    offsetY: scrollView.contentOffset.y, minOffsetY: minOffset, maxOffsetY: maxOffset,
                    trackTop: indicator.top + TimelineScrollDateLabelMotion.trackMargin,
                    trackBottom: host.bounds.height - indicator.bottom - TimelineScrollDateLabelMotion.trackMargin,
                    labelHeight: size.height, avoiding: avoidedBands)
            else {
                view.alpha = 0  // No free place on the track (an extreme fold or a tiny window).
                return
            }
            view.alpha = 1
            let maxX = host.bounds.width - host.safeAreaInsets.right - TimelineScrollDateLabelMotion.indicatorGap
            let frame = CGRect(
                x: (maxX - size.width).rounded(), y: (centerY - size.height / 2).rounded(),
                width: size.width, height: size.height)
            if view.frame != frame { view.frame = frame }
            #if DEBUG
                notePlacementForTests()
            #endif
        }

        /// Ends the label with its host: no build, hide or callback outlives it.
        func retire() {
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
            let animated = !reduceMotion && controller.animatesLastChange
            if presentation.isVisible != isShown {
                isShown = presentation.isVisible
                if isShown { host?.bringSubviewToFront(view) }
                // Suppression, a route change or stale content hides at once; shows and the linger hide fade.
                view.setShown(isShown, animated: animated)
                #if DEBUG
                    if isShown { showCount += 1 }
                #endif
            } else if !isShown, !animated {
                view.setShown(false, animated: false)  // Stops a running fade-out at once.
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
