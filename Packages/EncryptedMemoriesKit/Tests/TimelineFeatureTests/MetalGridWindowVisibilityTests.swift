import AppKit
import GridCore
import MetalKit
import PhotosCore
import Testing

@testable import TimelineFeature

@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalGridWindowVisibilityTests {
    @Test func becomingVisibleRequestsFrameWithoutScrolling() throws {
        let fixture = try Fixture()
        defer { fixture.detach() }
        let origin = fixture.host.coordinator.clipView?.bounds.origin

        for _ in 0..<3 {
            fixture.window.testOcclusionState = []
            fixture.notifyVisibility()
            #expect(!fixture.host.framePump.shouldTick)

            fixture.window.testOcclusionState = [.visible]
            fixture.notifyVisibility()
            #expect(fixture.host.framePump.shouldTick)
            #expect(fixture.host.coordinator.clipView?.bounds.origin == origin)
        }
    }

    @Test func unrelatedAndDetachedWindowsDoNotRequestFrames() throws {
        let fixture = try Fixture()
        defer { fixture.detach() }
        let other = VisibilityWindow()
        other.testOcclusionState = [.visible]
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: other)
        #expect(!fixture.host.framePump.shouldTick)

        fixture.detach()
        fixture.window.testOcclusionState = [.visible]
        fixture.notifyVisibility()
        #expect(!fixture.host.framePump.shouldTick)
    }

    @Test func movingToAnotherWindowRewiresVisibilityObserver() throws {
        let fixture = try Fixture()
        let nextWindow = VisibilityWindow()
        defer {
            fixture.detach()
            nextWindow.contentView = nil
        }
        fixture.detach()
        nextWindow.contentView = fixture.host
        fixture.window.testOcclusionState = [.visible]
        fixture.notifyVisibility()
        #expect(!fixture.host.framePump.shouldTick)

        nextWindow.testOcclusionState = [.visible]
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: nextWindow)
        #expect(fixture.host.framePump.shouldTick)
    }

    @Test func coldStartWithoutDrawableRetainsFrameAndDoesNotReportReady() throws {
        let fixture = try Fixture()
        defer { fixture.detach() }
        let view = UnavailableDrawableView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            device: try #require(MTLCreateSystemDefaultDevice()))
        var reportedReady = false
        fixture.host.coordinator.onContentReady = { reportedReady = true }
        var pump = GridFramePump()

        for _ in 0..<3 {
            let beganTick = pump.beginTick()
            #expect(beganTick)
            fixture.host.coordinator.draw(in: view)
            #expect(fixture.host.coordinator.lastRenderOutcome == .noDrawable)
            let keepsTicking = pump.completeTick(fixture.host.coordinator.lastRenderOutcome)
            #expect(keepsTicking)
            #expect(!reportedReady)
            #expect(fixture.source.imageReads == 0)
        }
    }

    @MainActor
    private struct Fixture {
        let window: VisibilityWindow
        let host: MetalGridScrollHost
        let source: ReadyGridDataSource

        init() throws {
            _ = NSApplication.shared
            window = VisibilityWindow()
            source = try ReadyGridDataSource()
            let device = try #require(MTLCreateSystemDefaultDevice())
            host = try #require(
                MetalGridScrollHost(
                    device: device, dataSource: source,
                    gridProfile: .testRegularTimeline))
            window.contentView = host
        }

        func notifyVisibility() {
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }

        func detach() {
            host.removeFromSuperview()
            window.contentView = nil
        }
    }
}

/// Control the WindowServer input while exercising the real host's notification registration.
@MainActor
private final class VisibilityWindow: NSWindow {
    var testOcclusionState: NSWindow.OcclusionState = []
    override var occlusionState: NSWindow.OcclusionState { testOcclusionState }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }
}

@MainActor
private final class ReadyGridDataSource: MetalGridDataSource {
    let label = "visibility-test"
    let sectionCounts = [1]
    let flatUIDs = [PhotoUID(volumeID: "test", nodeID: "ready-image")]
    private let thumbnail: CGImage
    private(set) var imageReads = 0
    var onImagesAvailable: (() -> Void)?

    init() throws {
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        thumbnail = try #require(context.makeImage())
    }

    func hasImage(for uid: PhotoUID) -> Bool { true }
    func image(for uid: PhotoUID) -> CGImage? {
        imageReads += 1
        return thumbnail
    }
    func warm(_ requests: [ThumbnailRequest]) {}
}

@MainActor
private final class UnavailableDrawableView: MTKView {
    override var currentDrawable: (any CAMetalDrawable)? { nil }
}
