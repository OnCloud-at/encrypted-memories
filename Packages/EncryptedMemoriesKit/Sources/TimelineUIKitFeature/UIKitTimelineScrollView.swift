#if canImport(UIKit)
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
            if showsVerticalScrollIndicator {
                for child in children {
                    let rect = child.convert(child.bounds, to: self)
                    guard rect.width > 0, rect.height > rect.width, rect.minX >= bounds.midX else { continue }
                    if indicator == nil || rect.maxX > indicator!.maxX { indicator = rect }
                }
            }
            guard indicator != verticalIndicatorRect else { return }
            verticalIndicatorRect = indicator
            onVerticalIndicatorLayout?(indicator)
        }
    }
#endif
