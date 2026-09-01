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

enum MobileViewerHeaderLayout {
    static let horizontalPadding: CGFloat = 12
    static let buttonWidth: CGFloat = 44
    static let minimumTitleWidth: CGFloat = 128
    static let maximumTitleWidth: CGFloat = 280
    private static let titleSpacing: CGFloat = 8

    static func titleWidth(containerWidth: CGFloat) -> CGFloat {
        let available = containerWidth - 2 * (horizontalPadding + buttonWidth + titleSpacing)
        return min(maximumTitleWidth, max(minimumTitleWidth, available))
    }
}

enum MobileViewerBottomLayout {
    static let horizontalPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 8
    static let actionButtonSize: CGFloat = 52
    static let centerPillWidth: CGFloat = 108
    static let filmstripHeight: CGFloat = 54
    static let bottomPadding: CGFloat = 8

    /// Keeps the media layout stable when controls or video transport appear.
    static var baseChromeHeight: CGFloat {
        actionButtonSize + rowSpacing + filmstripHeight + bottomPadding
    }

    static var minimumRequiredWidth: CGFloat {
        2 * horizontalPadding + 2 * actionButtonSize + 2 * rowSpacing + centerPillWidth
    }

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

/// Keeps controls on bounded overlays so the native media view retains its gestures.
struct MobileViewerChromeOverlay<Content: View, TopChrome: View, BottomChrome: View>: View {
    let showsChrome: Bool
    private let content: Content
    private let topChrome: TopChrome
    private let bottomChrome: BottomChrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let presentation = ViewerChromePresentationStyle.standard

    init(
        showsChrome: Bool,
        @ViewBuilder content: () -> Content,
        @ViewBuilder topChrome: () -> TopChrome,
        @ViewBuilder bottomChrome: () -> BottomChrome
    ) {
        self.showsChrome = showsChrome
        self.content = content()
        self.topChrome = topChrome()
        self.bottomChrome = bottomChrome()
    }

    var body: some View {
        content
            .overlay(alignment: .top) {
                topChrome
                    .opacity(showsChrome ? 1 : 0)
                    .offset(y: reduceMotion || showsChrome ? 0 : -presentation.edgeOffset)
                    .allowsHitTesting(showsChrome)
                    .accessibilityHidden(!showsChrome)
            }
            .overlay(alignment: .bottom) {
                bottomChrome
                    .opacity(showsChrome ? 1 : 0)
                    .offset(y: reduceMotion || showsChrome ? 0 : presentation.edgeOffset)
                    .allowsHitTesting(showsChrome)
                    .accessibilityHidden(!showsChrome)
            }
            .animation(
                MobileViewerMotionPolicy.animation(
                    .easeInOut(duration: presentation.visibilityDuration),
                    reduceMotion: reduceMotion
                ),
                value: showsChrome
            )
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
