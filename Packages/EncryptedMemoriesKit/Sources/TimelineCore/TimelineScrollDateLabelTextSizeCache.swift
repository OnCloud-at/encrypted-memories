import CoreGraphics
import Foundation

/// Shared padding, outward rounding and cached native text measurement. The adapter owns font and cell fitting.
public struct TimelineScrollDateLabelTextSizeCache {
    private let padding: CGSize
    private var cachedSize: CGSize?

    public init(horizontalPadding: CGFloat, verticalPadding: CGFloat) {
        padding = CGSize(width: horizontalPadding, height: verticalPadding)
    }

    public mutating func fittingSize(measuring measure: () -> CGSize) -> CGSize {
        if let cachedSize { return cachedSize }
        let size = measure()
        let fitting = CGSize(
            width: ceil(size.width) + 2 * padding.width, height: ceil(size.height) + 2 * padding.height)
        cachedSize = fitting
        return fitting
    }

    public mutating func invalidate() { cachedSize = nil }

    public func contentFrame(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: padding.width, dy: padding.height)
    }
}
