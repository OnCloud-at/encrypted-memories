#if canImport(UIKit)
    import TimelineAppleAdapter
    import TimelineCore
    import UIKit

    /// The transient month and year label beside the native vertical scroll indicator. Display only: it takes no
    /// touches and is not an accessibility element, so the grid's hit testing and its accessible dates stay as they
    /// are, and VoiceOver announces no month changes.
    final class UIKitTimelineScrollDateLabelView: UIView {
        private let glass = UIVisualEffectView(effect: nil)
        /// One material for every show. A new effect object per show cost 5 to 7 ms per show and hide; the reused one
        /// 2 to 3 ms (iPhone 17 simulator, Debug).
        private let glassEffect = UIGlassEffect(style: .regular)
        private let label = UILabel()
        private var textSize = TimelineScrollDateLabelTextSizeCache(horizontalPadding: 12, verticalPadding: 6)

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
                view.textSize.invalidate()
                view.setNeedsLayout()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        var text: String? { label.text }

        func setText(_ text: String) {
            guard label.text != text else { return }
            label.text = text
            textSize.invalidate()
            setNeedsLayout()
        }

        /// The label size for the current text and Dynamic Type size.
        var fittingSize: CGSize {
            textSize.fittingSize { label.intrinsicContentSize }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            glass.frame = bounds
            label.frame = textSize.contentFrame(in: bounds)
        }

        /// Horizontal motion is independent of the viewport position, which continues to update every scroll event.
        func setDragOffset(_ offset: CGFloat, duration: TimeInterval?, tracking: Bool) {
            LayerPresentation.setTranslationX(-offset, on: layer, duration: duration, tracking: tracking)
        }

        /// Fades the glass in or out. Glass materializes by animating its effect, not the view's alpha. Reduce Motion
        /// shows and hides at once.
        func setShown(_ shown: Bool, duration: TimeInterval?) {
            let changes = { [self] in
                glass.effect = shown ? glassEffect : nil
                label.alpha = shown ? 1 : 0
            }
            if shown { isHidden = false }
            guard let duration else {
                for layer in [layer, glass.layer, label.layer] { layer.removeAllAnimations() }
                UIView.performWithoutAnimation(changes)
                isHidden = !shown
                return
            }
            UIView.animate(
                withDuration: duration, delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, shown ? .curveEaseOut : .curveEaseIn],
                animations: changes
            ) { [weak self] finished in
                guard let self, finished, !shown, self.label.alpha == 0 else { return }
                self.isHidden = true
            }
        }
    }

#endif
