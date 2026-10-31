import AppKit
import GridCore
import MetalGridComposeCore
import MetalKit
import PhotosCore
import Testing
import TimelineCore

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

    @Test func missingVisiblePhotoAnimatesUntilReduceMotionIsEnabled() throws {
        let fixture = try Fixture()
        defer { fixture.detach() }
        let coordinator = fixture.host.coordinator
        let id = try #require(fixture.source.flatUIDs.first)
        var redraws = 0
        coordinator.onRequestRedraw = { redraws += 1 }
        coordinator.setPlaceholderReduceMotion(false)
        coordinator.updatePlaceholderPulse(visibleUIDs: [id], now: 1)
        #expect(coordinator.hasActiveAnimation(in: [id], now: 1))
        coordinator.setPlaceholderReduceMotion(true)
        coordinator.updatePlaceholderPulse(visibleUIDs: [id], now: 1.1)
        #expect(!coordinator.hasActiveAnimation(in: [id], now: 1.1))
        coordinator.setPlaceholderReduceMotion(false)
        coordinator.updatePlaceholderPulse(visibleUIDs: [id], now: 6)
        #expect(!coordinator.hasActiveAnimation(in: [id], now: 6))
        coordinator.setDataSource(fixture.source)
        coordinator.updatePlaceholderPulse(visibleUIDs: [id], now: 7)
        #expect(!coordinator.hasActiveAnimation(in: [id], now: 7))
        #expect(redraws > 0)
    }

    @Test func aTileWhoseThumbnailFailedStaysStaticAndLetsTheDisplayLinkIdle() throws {
        let fixture = try Fixture()
        defer { fixture.detach() }
        let coordinator = fixture.host.coordinator
        let id = try #require(fixture.source.flatUIDs.first)
        fixture.source.retryable = false
        coordinator.setPlaceholderReduceMotion(false)
        coordinator.updatePlaceholderPulse(visibleUIDs: [id], now: 1)
        let animating = coordinator.hasActiveAnimation(in: [id], now: 1)
        #expect(!animating)
        var pump = GridFramePump()
        let began = pump.beginTick()
        let keepsTicking = pump.completeTick(.drawn(hasPendingWork: animating))
        #expect(began)
        #expect(!keepsTicking)
        fixture.source.retryable = true
        coordinator.updatePlaceholderPulse(visibleUIDs: [id], now: 2)
        #expect(coordinator.hasActiveAnimation(in: [id], now: 2))
    }

    @Test func everyTileSharesOneSweepThatEndsForAllOfThemTogether() throws {
        let fixture = try Fixture(count: 2)
        defer { fixture.detach() }
        let coordinator = fixture.host.coordinator
        let ids = fixture.source.flatUIDs
        coordinator.setPlaceholderReduceMotion(false)
        coordinator.updatePlaceholderPulse(visibleUIDs: [ids[0]], now: 1)
        coordinator.updatePlaceholderPulse(visibleUIDs: ids, now: 3)
        #expect(coordinator.hasActiveAnimation(in: ids, now: 3))
        coordinator.updatePlaceholderPulse(visibleUIDs: ids, now: 5.9)
        #expect(!coordinator.hasActiveAnimation(in: ids, now: 5.9))
    }

    @Test func theSweepRestartsWhenTheWindowBecomesVisibleAgain() throws {
        let fixture = try Fixture()
        defer { fixture.detach() }
        let coordinator = fixture.host.coordinator
        let id = try #require(fixture.source.flatUIDs.first)
        coordinator.setPlaceholderReduceMotion(false)
        fixture.window.testOcclusionState = [.visible]
        fixture.notifyVisibility()
        coordinator.updatePlaceholderPulse(visibleUIDs: [id], now: 1)
        #expect(coordinator.hasActiveAnimation(in: [id], now: 1))
        fixture.window.testOcclusionState = []
        fixture.notifyVisibility()
        fixture.window.testOcclusionState = [.visible]
        fixture.notifyVisibility()
        coordinator.updatePlaceholderPulse(visibleUIDs: [id], now: 100)
        #expect(coordinator.hasActiveAnimation(in: [id], now: 100))
        coordinator.updatePlaceholderPulse(visibleUIDs: [id], now: 105)
        #expect(!coordinator.hasActiveAnimation(in: [id], now: 105))
    }

    /// Uploads the tile's thumbnail through the coordinator's own texture cache, as a streamed frame does.
    private func loadThumbnail(_ id: PhotoUID, into coordinator: MetalGridCoordinator, source: ReadyGridDataSource) {
        _ = MetalGridFrameComposer.stream(
            cache: coordinator.cache, visibleIDs: [id], overscanIDs: [], effectiveUploadPixels: 64,
            allowUpgrade: false, hasImage: { _ in true }, canRetry: { _ in true },
            provideImage: { source.image(for: $0) })
    }

    @Test func replacingReadinessProxyRevokesOldAndRearmsNew() throws {
        let fixture = try Fixture()
        defer { fixture.detach() }
        let coordinator = fixture.host.coordinator
        let id = try #require(fixture.source.flatUIDs.first)
        loadThumbnail(id, into: coordinator, source: fixture.source)
        let old = GridProxy<PhotoUID>()
        let replacement = GridProxy<PhotoUID>()
        coordinator.connectReadinessProxy(old, revision: 4)
        coordinator.didRenderVisible([id])
        coordinator.connectReadinessProxy(replacement, revision: 7)
        var oldValues: [UInt64] = []
        var newValues: [UInt64] = []
        old.onContentReady = { oldValues.append($0) }
        replacement.onContentReady = { newValues.append($0) }
        #expect(oldValues.isEmpty)
        coordinator.didRenderVisible([id])
        #expect(newValues == [7])
        coordinator.connectReadinessProxy(nil, revision: 7)
        coordinator.setDataSource(fixture.source)
        #expect(oldValues.isEmpty)
    }

    @Test func pendingReadinessIsRevokedBySourceEpochAndDetachment() throws {
        for event in 0..<3 {
            let fixture = try Fixture()
            let coordinator = fixture.host.coordinator
            let id = try #require(fixture.source.flatUIDs.first)
            loadThumbnail(id, into: coordinator, source: fixture.source)
            let proxy = GridProxy<PhotoUID>()
            coordinator.onContentReady = { proxy.reportContentReady(revision: 4) }
            coordinator.onContentInvalidated = { proxy.invalidatePendingContentReady() }
            coordinator.didRenderVisible([id])
            switch event {
            case 0: coordinator.setDataSource(fixture.source)
            case 1: coordinator.setUploadBadges(PendingUploadBadges(contentEpochs: [id: 1]))
            default: fixture.detach()
            }
            var first = 0
            var revisions: [UInt64] = []
            proxy.onFirstContentReady = { first += 1 }
            proxy.onContentReady = { revisions.append($0) }
            #expect(first == 0)
            #expect(revisions.isEmpty)
            if event != 2 {
                coordinator.didRenderVisible([id])
                #expect(first == 1)
                #expect(revisions == [4])
                fixture.detach()
            }
        }
    }

    @Test func placeholderOnlyFramesNeverReportReadyAndTheFirstLoadedThumbnailReportsOnce() throws {
        let fixture = try Fixture(count: 2)
        defer { fixture.detach() }
        let coordinator = fixture.host.coordinator
        let ids = fixture.source.flatUIDs
        var readyCount = 0
        coordinator.onContentReady = { readyCount += 1 }
        coordinator.didRenderVisible([])
        coordinator.didRenderVisible(ids)
        coordinator.didRenderVisible(ids)
        #expect(readyCount == 0)
        loadThumbnail(ids[1], into: coordinator, source: fixture.source)
        coordinator.didRenderVisible(ids)
        coordinator.didRenderVisible(ids)
        #expect(readyCount == 1)
        coordinator.setDataSource(fixture.source)
        coordinator.didRenderVisible(ids)
        #expect(readyCount == 2)
    }

    @Test func aContentLoadFailureAfterPlaceholderFramesStillSurfaces() throws {
        let fixture = try Fixture()
        defer { fixture.detach() }
        let coordinator = fixture.host.coordinator
        let id = try #require(fixture.source.flatUIDs.first)
        let proxy = GridProxy<PhotoUID>()
        var state = LibraryLoadState.loadingContent(count: 1, usingCachedInventory: false)
        proxy.onFirstContentReady = { state = LibraryLoadPolicy.reduce(state, .firstContentReady) }
        coordinator.connectReadinessProxy(proxy, revision: 1)
        coordinator.didRenderVisible([id])
        #expect(state == .loadingContent(count: 1, usingCachedInventory: false))
        state = LibraryLoadPolicy.reduce(state, .contentLoadFailed(message: "offline"))
        #expect(state == .failed(message: "offline", retryable: true))
    }

    @MainActor
    private struct Fixture {
        let window: VisibilityWindow
        let host: MetalGridScrollHost
        let source: ReadyGridDataSource

        init(count: Int = 1) throws {
            _ = NSApplication.shared
            window = VisibilityWindow()
            source = try ReadyGridDataSource(count: count)
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
    let sectionCounts: [Int]
    let flatUIDs: [PhotoUID]
    private let thumbnail: CGImage
    private(set) var imageReads = 0
    var retryable = true
    var onImagesAvailable: (() -> Void)?

    init(count: Int = 1) throws {
        sectionCounts = [count]
        flatUIDs = (0..<count).map {
            PhotoUID(volumeID: "test", nodeID: count == 1 ? "ready-image" : "ready-image-\($0)")
        }
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        thumbnail = try #require(context.makeImage())
    }

    func hasImage(for uid: PhotoUID) -> Bool { true }
    func canRetryThumbnail(for uid: PhotoUID) -> Bool { retryable }
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
