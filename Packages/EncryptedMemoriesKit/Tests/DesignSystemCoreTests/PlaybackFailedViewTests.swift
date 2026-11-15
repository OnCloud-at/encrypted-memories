import PhotosCore
import Testing

@testable import DesignSystemCore

#if os(macOS)
    import AppKit
    import QuartzCore
    import SwiftUI
#endif

@Suite struct PlaybackFailedViewTests {
    /// The card draws the reason of the failure: two failures that both offer Try again differ only in their reason.
    @MainActor @Test func theCardDrawsTheReasonOfTheFailure() throws {
        #expect(VideoPlaybackError.networkUnavailable.userMessage != VideoPlaybackError.timedOut.userMessage)
        let network = try RenderedInk.pixels(PlaybackFailedView(.networkUnavailable, retry: {}))
        let timedOut = try RenderedInk.pixels(PlaybackFailedView(.timedOut, retry: {}))
        #expect(network != timedOut)
    }

    #if os(macOS)
        /// Every failure the viewer can show: the card offers a control, Try again, only when a new attempt can work.
        @MainActor @Test func theCardOffersTryAgainOnlyWhenANewAttemptCanWork() async throws {
            let errors: [VideoPlaybackError] = [
                .notVideo, .metadataUnavailable, .unsupportedCodec, .streamURLUnavailable, .rangeNotSupported,
                .decryptionFailed, .malformedContent, .networkUnavailable, .authExpired, .quotaOrRateLimited,
                .localFileError, .playerItemFailed(detail: nil), .timedOut, .unknown(detail: nil),
            ]
            var offered = 0
            for error in errors {
                let page = try await HostedPage(PlaybackFailedView(error, retry: {}), width: 375, height: 800)
                defer { page.close() }
                let offersControl = page.hasNativeControl()
                #expect(offersControl == error.isRetryable, "\(error)")
                if offersControl { offered += 1 }
            }
            // Both outcomes occur, so the check above can fail in either direction.
            #expect(offered > 0 && offered < errors.count)
        }

        /// On a narrow, tall Mac page, 375 by 800 points, the card keeps a margin to both edges and is only about as
        /// tall as its content (title, reason and Try again), far below the page height. The macOS unavailable view
        /// already hugs its content vertically here; the iOS host checks the same rule in its own test.
        @MainActor @Test func theCardKeepsAMarginOnANarrowTallPage() async throws {
            let page = try await HostedPage(PlaybackFailedView(.networkUnavailable, retry: {}), width: 375, height: 800)
            defer { page.close() }
            let card = try #require(page.materialFrame(), "the card draws no material")
            #expect(card.minX > 0, "the card touches the leading edge: \(card)")
            #expect(card.maxX < 375, "the card touches the trailing edge: \(card)")
            #expect(card.height < 400, "the card grows beyond its content: \(card)")
        }
    #endif
}

#if os(macOS)
    /// A view in a live window of a fixed size, so its native layers and views exist. Hosted SwiftUI builds no
    /// accessibility tree without an accessibility client, so the page reads layers and native subviews only.
    @MainActor
    private final class HostedPage {
        private let host: NSView
        private let window: NSWindow

        init(_ view: some View, width: CGFloat, height: CGFloat) async throws {
            _ = NSApplication.shared
            let frame = NSRect(x: 0, y: 0, width: width, height: height)
            host = NSHostingView(rootView: view.frame(width: width, height: height))
            host.frame = frame
            window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<10 {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }

        func close() {
            window.orderOut(nil)
        }

        /// The frame of the first material layer the view draws, in the page's coordinates.
        func materialFrame() -> CGRect? {
            func find(_ layer: CALayer) -> CGRect? {
                if NSStringFromClass(type(of: layer)) == "CABackdropLayer" {
                    return layer.convert(layer.bounds, to: host.layer)
                }
                return (layer.sublayers ?? []).lazy.compactMap(find).first
            }
            return host.layer.flatMap(find)
        }

        /// Whether the page holds a native control. SwiftUI draws text, symbols and the material into layers of the
        /// hosting view; a button adds native views (its key-view proxy and focus ring).
        func hasNativeControl() -> Bool {
            !host.subviews.isEmpty
        }
    }
#endif
