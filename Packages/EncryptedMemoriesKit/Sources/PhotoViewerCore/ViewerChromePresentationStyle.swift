import CoreGraphics
import Foundation

/// Portable timing and movement values for the viewer's existing chrome.
/// Platform views translate these values into native AppKit or UIKit animations.
public struct ViewerChromePresentationStyle: Equatable, Sendable {
    public let visibilityDuration: TimeInterval
    public let inspectorDuration: TimeInterval
    public let edgeOffset: CGFloat

    public init(
        visibilityDuration: TimeInterval,
        inspectorDuration: TimeInterval,
        edgeOffset: CGFloat
    ) {
        self.visibilityDuration = visibilityDuration
        self.inspectorDuration = inspectorDuration
        self.edgeOffset = edgeOffset
    }

    public static let standard = ViewerChromePresentationStyle(
        visibilityDuration: 0.20,
        inspectorDuration: 0.22,
        edgeOffset: 8
    )
}

/// One responsive geometry contract for the existing mobile viewer controls. Compact landscape moves the
/// action row into the top chrome, leaving only the filmstrip below the video transport.
public struct ViewerChromeLayoutProfile: Equatable, Sendable {
    public let controlSide: CGFloat
    public let filmstripHeight: CGFloat
    public let rowSpacing: CGFloat
    public let bottomPadding: CGFloat
    public let showsBottomActionRow: Bool

    public var bottomChromeHeight: CGFloat {
        filmstripHeight + bottomPadding + (showsBottomActionRow ? controlSide + rowSpacing : 0)
    }

    public static let regular = ViewerChromeLayoutProfile(
        controlSide: 52,
        filmstripHeight: 54,
        rowSpacing: 8,
        bottomPadding: 8,
        showsBottomActionRow: true
    )

    public static let compactLandscape = ViewerChromeLayoutProfile(
        controlSide: 44,
        filmstripHeight: 46,
        rowSpacing: 6,
        bottomPadding: 4,
        showsBottomActionRow: false
    )
}
