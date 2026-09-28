import UIKit

extension UIApplication {
    /// Several windows of the app can share the display: on iPadOS at every window width, and on the open inner
    /// display of iPhone Duo. iPhone Duo also reports multiple-scene support when it is closed, but its compact outer
    /// display shows one window at a time, and the iOS 27.1 simulator does not disconnect a closed second window there.
    @MainActor var showsSeveralWindows: Bool {
        supportsMultipleScenes
            && (UIDevice.current.userInterfaceIdiom == .pad
                || connectedScenes.contains {
                    ($0 as? UIWindowScene)?.traitCollection.horizontalSizeClass == .regular
                })
    }
}
