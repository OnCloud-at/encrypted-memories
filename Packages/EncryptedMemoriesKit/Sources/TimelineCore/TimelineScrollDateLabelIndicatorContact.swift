import CoreGraphics

/// One direct contact on the native scroll indicator, as every platform adapter tracks it: the single host-space
/// thumb snapshot that the label also uses, and the held finger sample. A pure value; the adapter supplies the
/// native geometry, the rendered opacity and the clamped track ends.
///
/// - Touch-down needs the closed thumb envelope and visible rendered opacity.
/// - A held contact continues through either callback order (touch before layout, or layout before touch) and past
///   a clamped track end.
/// - A separated movement ends the contact. It never binds again within the same touch.
public struct TimelineScrollDateLabelIndicatorContact: Equatable, Sendable {
    private struct Sample: Equatable, Sendable {
        var y: CGFloat
        var radius: CGFloat
    }

    /// The native thumb in host coordinates, or nil while the platform shows no thumb.
    public private(set) var thumbRect: CGRect?
    private var held: Sample?

    public init() {}

    public var isHeld: Bool { held != nil }

    /// Whether a touch-down at `point` lands on the visible native thumb.
    public func accepts(at point: CGPoint, radius: CGFloat, viewportRightX: CGFloat, effectiveAlpha: Float) -> Bool {
        guard let thumbRect else { return false }
        return TimelineScrollDateLabelGeometry.acceptsIndicatorContact(
            at: point, radius: radius, thumb: thumbRect, viewportRightX: viewportRightX,
            effectiveAlpha: effectiveAlpha)
    }

    /// Holds an accepted contact.
    public mutating func hold(at point: CGPoint, radius: CGFloat) {
        held = Sample(y: point.y, radius: radius)
    }

    /// A live finger sample. Returns true while the contact continues; false when this sample ended it, or when no
    /// contact is held.
    public mutating func move(to point: CGPoint, radius: CGFloat, atTop: Bool, atBottom: Bool) -> Bool {
        guard let previous = held else { return false }
        guard
            TimelineScrollDateLabelGeometry.continuesIndicatorContactAfterMove(
                at: point.y, previousY: previous.y, radius: radius, thumb: thumbRect ?? .zero,
                atTop: atTop, atBottom: atBottom)
        else {
            held = nil
            return false
        }
        held = Sample(y: point.y, radius: radius)
        return true
    }

    /// Stores the native thumb after the platform lays it out. Returns false when a held contact ended because
    /// neither the new nor the previous thumb aligns with the finger; fading never ends a hold. The adapter's
    /// clamped track ends are read only while a contact is held.
    public mutating func thumbDidLayout(
        _ thumb: CGRect?, clampedEnds: @autoclosure () -> (top: Bool, bottom: Bool)
    ) -> Bool {
        let previous = thumbRect
        thumbRect = thumb
        guard let held else { return true }
        let ends = clampedEnds()
        guard
            TimelineScrollDateLabelGeometry.continuesIndicatorContactAfterLayout(
                at: held.y, radius: held.radius, thumb: thumb ?? .zero, previousThumb: previous ?? .zero,
                atTop: ends.top, atBottom: ends.bottom)
        else {
            self.held = nil
            return false
        }
        return true
    }

    /// Ends the contact. Returns true when one was held, so the adapter reports the end exactly once.
    public mutating func end() -> Bool {
        guard held != nil else { return false }
        held = nil
        return true
    }
}
