import AVFoundation
import PhotoViewerCore
import PhotosCore
import SwiftUI

enum MobileViewerMotionPolicy {
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func duration(_ duration: TimeInterval, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : duration
    }
}

/// Geometry of the viewer's bottom safe-area content (the filmstrip rows). The bars themselves are native.
enum MobileViewerBottomLayout {
    static let horizontalPadding: CGFloat = 12

    static func profile(compactLandscape: Bool) -> ViewerChromeLayoutProfile {
        compactLandscape ? .compactLandscape : .regular
    }
}

enum MobileVideoPlaybackIntent {
    static func isActivelyPlaying(_ status: AVPlayer.TimeControlStatus) -> Bool {
        status == .playing
    }

    static func isBuffering(_ status: AVPlayer.TimeControlStatus) -> Bool {
        status == .waitingToPlayAtSpecifiedRate
    }

    static func showsLoadingIndicator(intendsToPlay: Bool, isActivelyPlaying: Bool) -> Bool {
        intendsToPlay && !isActivelyPlaying
    }

    static func reachedEnd(current: Double, duration: Double) -> Bool {
        duration > 0 && current >= duration - 0.05
    }
}

/// Prefers resolved media metadata over the timeline hint.
enum MobileViewerMediaRoute {
    static func isVideo(item: PhotoItem, resolvedKind: MediaKind?) -> Bool {
        resolvedKind == .video || (resolvedKind == nil && item.isVideo)
    }
}

/// Identifies Live Photo preparation without tying it to changing viewport geometry.
struct MobileLivePhotoMotionTaskID: Equatable {
    let item: PhotoItem
    let isCurrent: Bool
}
