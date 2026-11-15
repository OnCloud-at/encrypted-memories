import PhotosCore
import Testing

@testable import DesignSystemCore

#if os(macOS)
    import AppKit
    import QuartzCore
    import SwiftUI
#endif

@Suite struct PlaybackFailedViewTests {
    /// The card scrolls only when it is taller than its page by more than the tolerance, and it fits only when it is
    /// shorter by more than the tolerance. In between it keeps its form, so a sub-point rounding never switches it.
    @Test func theCardSwitchesItsFormOnlyBeyondTheTolerance() {
        let tolerance = PlaybackFailedView.fitTolerance
        #expect(tolerance == 0.5)
        #expect(PlaybackFailedView.scrolls(cardHeight: 300, pageHeight: 299.7, current: false) == false)
        #expect(PlaybackFailedView.scrolls(cardHeight: 300, pageHeight: 299.4, current: false) == true)
        #expect(PlaybackFailedView.scrolls(cardHeight: 299.7, pageHeight: 300, current: true) == true)
        #expect(PlaybackFailedView.scrolls(cardHeight: 299.4, pageHeight: 300, current: true) == false)
        #expect(PlaybackFailedView.scrolls(cardHeight: 300, pageHeight: 0, current: true) == true)
        #expect(PlaybackFailedView.scrolls(cardHeight: 0, pageHeight: 300, current: false) == false)
    }

    #if os(macOS)
        /// The card draws the reason of the failure: two failures that both offer Try again differ only in their
        /// reason. The page is drawn from a live window, as the viewer shows it.
        @MainActor @Test func theCardDrawsTheReasonOfTheFailure() async throws {
            #expect(VideoPlaybackError.networkUnavailable.userMessage != VideoPlaybackError.timedOut.userMessage)
            var drawn: [Data] = []
            for error: VideoPlaybackError in [.networkUnavailable, .timedOut] {
                let page = try await HostedPage(PlaybackFailedView(error, retry: {}), width: 375, height: 800)
                defer { page.close() }
                drawn.append(try #require(page.drawnPixels(), "the page draws nothing: \(error)"))
            }
            #expect(drawn[0] != drawn[1])
        }

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
                // Exactly one control: the hidden copy that measures the card must not add a second Try again.
                let controls = page.nativeControlCount()
                #expect(controls == (error.isRetryable ? 1 : 0), "\(error): \(controls) controls")
                let offersControl = controls > 0
                if offersControl { offered += 1 }
            }
            // Both outcomes occur, so the check above can fail in either direction.
            #expect(offered > 0 && offered < errors.count)
        }

        /// On a narrow, tall Mac page, 375 by 800 points, the card keeps a margin to both edges, is only about as tall
        /// as its content (title, reason and Try again), far below the page height, and sits in the middle of the page.
        @MainActor @Test func theCardKeepsAMarginOnANarrowTallPage() async throws {
            let page = try await HostedPage(PlaybackFailedView(.networkUnavailable, retry: {}), width: 375, height: 800)
            defer { page.close() }
            let card = try #require(page.materialFrame(), "the card draws no material")
            #expect(card.minX > 0, "the card touches the leading edge: \(card)")
            #expect(card.maxX < 375, "the card touches the trailing edge: \(card)")
            #expect(card.height < 400, "the card grows beyond its content: \(card)")
            #expect(abs(card.midY - 400) < 2, "the card is not in the middle of the page: \(card)")
        }

        /// A Mac page shorter than the card: the card starts at its margin at the top of the page and continues below
        /// the page, where scrolling reaches it.
        @MainActor @Test func theCardStartsAtItsMarginOnAShortPage() async throws {
            let page = try await HostedPage(PlaybackFailedView(.networkUnavailable, retry: {}), width: 375, height: 150)
            defer { page.close() }
            let card = try #require(page.materialFrame(), "the card draws no material")
            #expect(abs(card.minY - 16) < 1, "the card does not start at its margin: \(card)")
            #expect(card.height > 150, "the card is not taller than the short page: \(card)")
        }

        /// Outside a card that fits, the page below keeps every event: a hit test and a scroll reach the native view
        /// below, as the poster of the Mac viewer pages and zooms there. The card itself takes the events on its area.
        @MainActor @Test func aViewBelowTheCardKeepsTheEventsOutsideTheCard() async throws {
            let poster = PosterProbe()
            let view = ZStack {
                NativePoster(view: poster)
                PlaybackFailedView(.networkUnavailable, retry: {})
            }
            let page = try await HostedPage(view, width: 375, height: 800)
            defer { page.close() }
            let card = try #require(page.materialFrame(), "the card draws no material")
            let outside = CGPoint(x: card.midX, y: card.minY - 60)
            #expect(page.hitView(at: outside) === poster, "a view covers the page outside the card")
            page.scroll(at: outside)
            #expect(poster.scrollEvents > 0, "a scroll outside the card does not reach the view below")
            #expect(page.hitView(at: CGPoint(x: card.midX, y: card.midY)) !== poster, "the card lets events through")
        }

        /// The card scrolls when its page is a few points shorter than the card with its margin, and fits when the page
        /// is a few points taller, so the hidden copy that measures it has the card's own height.
        @MainActor @Test func theCardScrollsExactlyWhenItIsTallerThanItsPage() async throws {
            let tall = try await HostedPage(PlaybackFailedView(.networkUnavailable, retry: {}), width: 375, height: 800)
            let card = try #require(tall.materialFrame(), "the card draws no material")
            tall.close()
            let cardWithMargin = card.height + 32
            for (height, scrolls) in [(cardWithMargin + 4, false), (cardWithMargin - 4, true)] {
                let reported = ReportedScrolling()
                let view = PlaybackFailedView(.networkUnavailable, retry: {})
                    .onPreferenceChange(PlaybackFailedView.ScrollsKey.self) { reported.value = $0 }
                let page = try await HostedPage(view, width: 375, height: height)
                defer { page.close() }
                #expect(reported.value == scrolls, "page height \(height) for a card of \(cardWithMargin)")
            }
        }

        /// The page learns that the card scrolls only when the card is taller than the page, so a page with its own
        /// vertical drag gives every pan to the card's scrolling only then.
        @MainActor @Test func theCardReportsScrollingOnlyOnAPageShorterThanIt() async throws {
            for (height, scrolls) in [(CGFloat(800), false), (150, true)] {
                let reported = ReportedScrolling()
                let view = PlaybackFailedView(.networkUnavailable, retry: {})
                    .onPreferenceChange(PlaybackFailedView.ScrollsKey.self) { reported.value = $0 }
                let page = try await HostedPage(view, width: 375, height: height)
                defer { page.close() }
                #expect(reported.value == scrolls, "page height \(height)")
            }
        }
    #endif
}

#if os(macOS)
    @MainActor
    private final class ReportedScrolling {
        var value = false
    }

    /// A native view that counts the scroll events it receives, like the poster view of the Mac viewer.
    @MainActor
    private final class PosterProbe: NSView {
        var scrollEvents = 0

        override func scrollWheel(with event: NSEvent) {
            scrollEvents += 1
        }
    }

    private struct NativePoster: NSViewRepresentable {
        let view: PosterProbe

        func makeNSView(context: Context) -> PosterProbe { view }
        func updateNSView(_ nsView: PosterProbe, context: Context) {}
    }

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

        /// The pixels the page draws.
        func drawnPixels() -> Data? {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.bitmapData.map { Data(bytes: $0, count: bitmap.bytesPerRow * bitmap.pixelsHigh) }
        }

        /// The frame of the card's material in the page's coordinates.
        func materialFrame() -> CGRect? {
            host.layer.flatMap { MaterialLayerFrames.largest(below: $0, in: $0) }
        }

        /// The view that a click at `point` (page coordinates) reaches.
        func hitView(at point: CGPoint) -> NSView? {
            host.hitTest(host.convert(point, to: host.superview))
        }

        /// Sends one two-finger scroll at `point` (page coordinates) through the window, as the system does.
        func scroll(at point: CGPoint) {
            let screenPoint = window.convertPoint(toScreen: host.convert(point, to: nil))
            let screenHeight = NSScreen.screens.first?.frame.maxY ?? 0
            guard
                let event = CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -40, wheel3: 0)
            else { return }
            event.location = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            guard let scroll = NSEvent(cgEvent: event) else { return }
            window.sendEvent(scroll)
        }

        /// How many native controls the page holds. SwiftUI draws text, symbols and the material into layers; each
        /// button adds a key-view proxy, the native view that keyboard focus moves to.
        func nativeControlCount() -> Int {
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            return views(host).filter { NSStringFromClass(type(of: $0)).contains("KeyViewProxy") }.count
        }
    }
#endif
