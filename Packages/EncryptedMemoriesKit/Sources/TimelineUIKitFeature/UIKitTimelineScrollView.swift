#if canImport(UIKit)
    import TimelineAppleAdapter
    import UIKit

    /// Forwards the native vertical indicator's public UIView geometry after UIKit lays it out. It never reads a
    /// private class, selector or property. The owned content and edge-effect views span the width; the native
    /// vertical indicator is the narrow vertical child in the trailing half of this physical-right scroll surface.
    final class UIKitTimelineScrollView: UIScrollView {
        var onVerticalIndicatorLayout: ((CGRect?) -> Void)? {
            didSet { onVerticalIndicatorLayout?(verticalIndicatorRect) }
        }
        // Track child lifecycle instead of asking for `subviews` (an array) on every scrolling layout.
        private var children: [UIView] = []
        private(set) var verticalIndicatorRect: CGRect?
        private weak var verticalIndicatorView: UIView?
        /// UIKit retains the thumb frame after it fades. Read the current rendered opacity and every ancestor's
        /// visibility only at touch-down; an accepted contact survives the thumb's later fade.
        var verticalIndicatorEffectiveAlpha: Float {
            guard let verticalIndicatorView else { return 0 }
            return LayerPresentation.effectiveOpacity(of: verticalIndicatorView.layer)
        }

        /// The native scrollable range includes adjusted insets and collapses for content shorter than the viewport.
        var verticalOffsetRange: ClosedRange<CGFloat> {
            let minimum = -adjustedContentInset.top
            return minimum...max(minimum, contentSize.height - bounds.height + adjustedContentInset.bottom)
        }

        var clampedVerticalEnds: (top: Bool, bottom: Bool) {
            let range = verticalOffsetRange
            // UIKit can round a fractional endpoint to the nearest device pixel.
            let tolerance = 0.5 / traitCollection.displayScale
            return (contentOffset.y <= range.lowerBound + tolerance, contentOffset.y >= range.upperBound - tolerance)
        }

        override func didAddSubview(_ subview: UIView) {
            super.didAddSubview(subview)
            children.append(subview)
        }

        override func willRemoveSubview(_ subview: UIView) {
            children.removeAll { $0 === subview }
            super.willRemoveSubview(subview)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            var indicator: CGRect?
            var indicatorView: UIView?
            if showsVerticalScrollIndicator {
                for child in children {
                    let rect = child.convert(child.bounds, to: self)
                    guard rect.width > 0, rect.height > rect.width, rect.minX >= bounds.midX else { continue }
                    if indicator == nil || rect.maxX > indicator!.maxX {
                        indicator = rect
                        indicatorView = child
                    }
                }
            }
            verticalIndicatorView = indicatorView
            guard indicator != verticalIndicatorRect else { return }
            verticalIndicatorRect = indicator
            onVerticalIndicatorLayout?(indicator)
        }
    }
#endif
