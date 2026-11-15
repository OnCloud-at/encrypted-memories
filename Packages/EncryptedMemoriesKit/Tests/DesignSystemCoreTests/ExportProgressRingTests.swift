import Testing

@testable import DesignSystemCore

#if os(macOS)
    import AppKit
    import SwiftUI

    /// The export ring in a live window: the pointer reaches the ring on its whole item, also in the middle of the
    /// empty pie, so a tooltip on the ring can show from the start of an export.
    @Suite struct ExportProgressRingTests {
        @MainActor @Test func theWholeRingAnswersThePointerWhileItsPieIsEmpty() async throws {
            for fraction in [0.0, 0.03] {
                let below = NSView()
                let host = NSHostingView(
                    rootView: ZStack {
                        NativeView(view: below)
                        ExportProgressRing(fraction: fraction)
                    }
                    .frame(width: 30, height: 18))
                let frame = NSRect(x: 0, y: 0, width: 30, height: 18)
                host.frame = frame
                let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                defer { window.orderOut(nil) }
                for _ in 0..<10 {
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
                }
                for point in [CGPoint(x: 15, y: 9), CGPoint(x: 3, y: 9), CGPoint(x: 27, y: 9), CGPoint(x: 1, y: 1)] {
                    let hit = host.hitTest(host.convert(point, to: host.superview))
                    #expect(hit != nil, "nothing answers at \(point), fraction \(fraction)")
                    #expect(hit !== below, "the pointer passes through the ring at \(point), fraction \(fraction)")
                }
            }
        }
    }

    private struct NativeView: NSViewRepresentable {
        let view: NSView

        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
#endif
