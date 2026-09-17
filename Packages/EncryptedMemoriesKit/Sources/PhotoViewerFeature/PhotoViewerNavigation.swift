import SwiftUI

/// Previous and Next actions of the focused photo viewer, published to the scene so the app's View menu can
/// offer them as native commands.
public struct PhotoViewerNavigation {
    public let canGoPrevious: Bool
    public let canGoNext: Bool
    public let goPrevious: () -> Void
    public let goNext: () -> Void
}

extension FocusedValues {
    @Entry public var photoViewerNavigation: PhotoViewerNavigation?
}
