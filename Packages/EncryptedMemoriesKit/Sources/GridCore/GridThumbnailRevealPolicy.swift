/// Shared timing curve for a thumbnail that changes from the grid surface placeholder to real media.
///
/// The reveal is intentionally short: it softens an E2EE/network arrival without making a ready thumbnail
/// feel delayed. Geometry never participates, so scrolling, pinching, and layout remain fully responsive.
package enum GridThumbnailRevealPolicy {
    package static let duration: Double = 0.18

    package static func opacity(elapsed: Double) -> Float {
        guard duration > 0 else { return 1 }
        let progress = min(1, max(0, elapsed / duration))
        let remaining = 1 - progress
        return Float(1 - remaining * remaining * remaining)
    }

    package static func isActive(elapsed: Double) -> Bool {
        elapsed >= 0 && elapsed < duration
    }
}
