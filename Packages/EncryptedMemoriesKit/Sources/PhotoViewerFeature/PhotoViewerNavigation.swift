import SwiftUI

/// Previous, Next and Close of the focused photo viewer, published to the scene so the app's View menu can
/// offer them as native commands.
///
/// Close needs the menu route as well: `onExitCommand` only fires while the viewer or one of its descendants
/// holds focus, and the native inspector column takes focus away from the media.
public struct PhotoViewerNavigation {
    public let canGoPrevious: Bool
    public let canGoNext: Bool
    public let goPrevious: () -> Void
    public let goNext: () -> Void
    public let close: () -> Void
}

extension FocusedValues {
    @Entry public var photoViewerNavigation: PhotoViewerNavigation?
}
