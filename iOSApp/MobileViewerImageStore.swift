import PhotosCore
import os

/// Debug-only viewer loading diagnostics for app-side viewer pages. The display-image store itself
/// fetches, decodes within bounds, and caches through the shared
/// `UIKitViewerImageStore` in `PhotoViewerUIKitAdapter`.
enum MobileViewerLog {
    static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "ViewerPerf")
    #if DEBUG
        static let isEnabled = true
    #else
        static let isEnabled = false
    #endif

    static func short(_ uid: PhotoUID) -> String { String(uid.nodeID.suffix(6)) }
}
