import Foundation

/// Integer pixel dimensions used by the temporal-cover quality policy.
public struct TimelineTemporalPixelSize: Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var longestEdge: Int { max(width, height) }
}

/// Selects a decode size that can fill a rendered temporal card without upscaling.
///
/// The source can be a Proton thumbnail, preview, or original. Callers inspect the
/// real encoded pixel dimensions instead of assuming that a requested decode size
/// increased the source quality.
public enum TimelineTemporalCoverResolutionPolicy {
    public static func sourceFillsTargetWithoutUpscaling(
        source: TimelineTemporalPixelSize,
        target: TimelineTemporalPixelSize
    ) -> Bool {
        guard source.width > 0, source.height > 0,
            target.width > 0, target.height > 0
        else { return false }

        return source.width >= target.width && source.height >= target.height
    }

    /// The longest output edge needed for an aspect-fill decode.
    ///
    /// The result never exceeds the source's longest edge. A landscape card backed
    /// by a portrait source therefore decodes enough of the portrait's long edge to
    /// keep the cropped card sharp.
    public static func requiredDecodeLongestEdge(
        source: TimelineTemporalPixelSize,
        target: TimelineTemporalPixelSize
    ) -> Int {
        guard source.width > 0, source.height > 0,
            target.width > 0, target.height > 0
        else { return max(1, min(source.longestEdge, target.longestEdge)) }

        let fillScale = max(
            Double(target.width) / Double(source.width),
            Double(target.height) / Double(source.height)
        )
        let requested = Int(ceil(Double(source.longestEdge) * min(1, fillScale)))
        return max(1, min(source.longestEdge, requested))
    }
}
