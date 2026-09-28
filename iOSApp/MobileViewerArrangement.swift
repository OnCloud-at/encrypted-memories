import PhotoViewerCore
import SwiftUI

/// The viewer's media and its bottom accessory (the filmstrip) in one arrangement.
///
/// On iOS 27.1 an overlay `ArrangementView` holds them: while the display is whole it lays the accessory over the
/// media, and the media ends above the accessory the way the filmstrip has always shortened it. While iPhone Duo is
/// partially open, the arrangement puts the media on one part of the display and the accessory on the other, so
/// neither crosses the fold. The media keeps its one pager and player; only its frame changes. Earlier systems and
/// SDKs keep the filmstrip as bottom safe-area content, which lays the media out the same way.
struct MobileViewerArrangement<Media: View, Accessory: View>: View {
    /// The chrome toggle hides the accessory; the media then fills the whole area in the same animation.
    let showsAccessory: Bool
    @ViewBuilder let media: Media
    @ViewBuilder let accessory: Accessory

    @State private var mediaFrame: CGRect = .null
    @State private var accessoryFrame: CGRect = .null

    var body: some View {
        #if canImport(SwiftUI, _version: 8.0.85)
            if #available(iOS 27.1, *) {
                arranged
            } else {
                stacked
            }
        #else
            stacked
        #endif
    }

    private var stacked: some View {
        media.safeAreaInset(edge: .bottom, spacing: 0) {
            if showsAccessory { accessory }
        }
    }

    #if canImport(SwiftUI, _version: 8.0.85)
        @available(iOS 27.1, *)
        private var arranged: some View {
            // Apple's media example: the controls are the primary view, laid over the video in the whole display
            // and moved to the trailing or bottom part while the device is partially open.
            ArrangementView {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if showsAccessory {
                        accessory
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .global)
                            } action: {
                                accessoryFrame = $0
                            }
                    }
                }
            } secondary: {
                // The last measured accessory frame stays valid while it is hidden, so showing it again shortens
                // the media in the same animation instead of one layout pass later.
                media
                    .safeAreaPadding(
                        .bottom,
                        showsAccessory
                            ? ViewerArrangementGeometry.stackedBottomInset(accessory: accessoryFrame, media: mediaFrame)
                            : 0
                    )
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        mediaFrame = $0
                    }
            }
            .arrangementViewStyle(.overlay)
        }
    #endif
}
