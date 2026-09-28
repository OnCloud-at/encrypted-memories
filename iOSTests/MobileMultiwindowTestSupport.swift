import UIKit

extension UIApplication {
    /// The multi-window tests open and close a second window of the app, which iPadOS supports at every window width.
    /// iPhone Duo also reports multiple-scene support, but closed it shows one window at a time, also in landscape
    /// where its outer display has a regular width, and the iOS 27.1 simulator does not disconnect a closed second
    /// window there. Two windows on the open inner display remain a manual check, because a test cannot open the
    /// device.
    @MainActor var showsSeveralWindows: Bool {
        supportsMultipleScenes && UIDevice.current.userInterfaceIdiom == .pad
    }
}
