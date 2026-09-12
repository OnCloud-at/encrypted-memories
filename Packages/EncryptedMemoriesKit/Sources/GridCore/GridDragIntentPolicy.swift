import CoreGraphics

/// A pointer drag starting near a photo's visible edge belongs to rectangle selection.
/// Click hit testing stays unchanged; only drag-out uses this smaller interior.
public enum GridDragIntentPolicy {
    public static func dragOutRect(visiblePhotoRect: CGRect) -> CGRect {
        guard !visiblePhotoRect.isEmpty, !visiblePhotoRect.isInfinite else { return .null }
        let inset = min(12, min(visiblePhotoRect.width, visiblePhotoRect.height) * 0.15)
        return visiblePhotoRect.insetBy(dx: inset, dy: inset)
    }

    public static func startsDragOut(at point: CGPoint, visiblePhotoRect: CGRect) -> Bool {
        dragOutRect(visiblePhotoRect: visiblePhotoRect).contains(point)
    }
}
