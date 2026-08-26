import SwiftUI

/// Shared presentation for the full-window library loading cover. Core owns every visual and accessibility
/// decision; platform adapters provide only the native material that samples content behind this view.
public struct LibraryLoadingCover<Backdrop: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let isPresented: Bool
    private let accessibilityLabel: String
    private let activityMessage: String?
    private let activityState: LibraryActivityBannerState
    private let showsLoadingContent: Bool
    private let backdrop: (Bool) -> Backdrop

    public init(
        isPresented: Bool,
        accessibilityLabel: String,
        activityMessage: String? = nil,
        activityState: LibraryActivityBannerState = .working,
        // A host may retain the exact same backdrop while presenting its own interactive center content.
        showsLoadingContent: Bool = true,
        @ViewBuilder backdrop: @escaping (_ isActive: Bool) -> Backdrop
    ) {
        self.isPresented = isPresented
        self.accessibilityLabel = accessibilityLabel
        self.activityMessage = activityMessage
        self.activityState = activityState
        self.showsLoadingContent = showsLoadingContent
        self.backdrop = backdrop
    }

    public var body: some View {
        ZStack {
            if reduceTransparency {
                if isPresented {
                    ProtonColor.backgroundNorm
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            } else {
                // The adapter stays mounted. UIKit must animate its effect at alpha 1; AppKit may animate
                // its native surface. Parent opacity would render UIKit material incorrectly.
                backdrop(isPresented)
                    .ignoresSafeArea()
            }

            if isPresented && showsLoadingContent {
                LoadingMark()
                    .frame(
                        width: LibraryLoadingCoverMetrics.markSize,
                        height: LibraryLoadingCoverMetrics.markSize
                    )
                    .shadow(color: .black.opacity(0.22), radius: 16)
                    .transition(reduceMotion ? .identity : .scale(scale: 0.96).combined(with: .opacity))

                if let activityMessage {
                    LibraryActivityBanner(message: activityMessage, state: activityState)
                        .libraryLoadingActivityTransitionSource()
                        .offset(y: LibraryLoadingCoverMetrics.activityBannerOffset)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Keep the cover centered while native toolbar and safe-area insets settle.
        .ignoresSafeArea()
        .animation(
            reduceMotion ? nil : .easeInOut(duration: LibraryLoadingCoverMetrics.fadeDuration),
            value: isPresented
        )
        .allowsHitTesting(isPresented && showsLoadingContent)
        .accessibilityHidden(!isPresented || !showsLoadingContent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// One set of loading-cover geometry and motion values for every Apple platform.
public enum LibraryLoadingCoverMetrics {
    public static let fadeDuration = 0.32
    public static let markSize: CGFloat = 72
    public static let activityBannerOffset: CGFloat = 92
}
