import AppKit
import GridCore
import MetalKit
import PhotosCore
import Testing
import TimelineCore

@testable import TimelineFeature

@MainActor
@Suite(.serialized)
struct MetalGridScrollDateLabelTextTests {
    /// The text field reports alignment insets, so its frame must be wider than the text. Every month in two locales
    /// fits its native cell and keeps equal padding on both sides.
    @Test(arguments: ["en_US", "de_AT"])
    func everyMonthFitsItsNativeTextCell(localeID: String) throws {
        _ = NSApplication.shared
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let items = (1...12).map { month in
            PhotoItem(
                uid: PhotoUID(volumeID: "text", nodeID: "\(month)"),
                captureTime: calendar.date(from: DateComponents(year: 2025, month: month, day: 3))!,
                mediaType: "image/jpeg")
        }
        let index = try #require(
            TimelineScrollDateIndex.build(
                items: items, revision: 1, calendar: calendar, locale: Locale(identifier: localeID)))
        let view = MetalGridScrollDateLabelView()
        let glass = try #require(view.subviews.compactMap { $0 as? NSGlassEffectView }.first)
        let content = try #require(glass.contentView)
        let field = try #require(content.subviews.compactMap { $0 as? NSTextField }.first)
        let cell = try #require(field.cell)
        for flatIndex in items.indices {
            let text = try #require(index.month(containing: flatIndex)?.text)
            view.setText(text)
            view.frame.size = view.labelSize
            view.layoutSubtreeIfNeeded()
            let alignment = field.alignmentRect(forFrame: field.frame)
            #expect(field.frame.width >= cell.cellSize.width, "\(localeID): \(text) fits its native cell")
            #expect(
                alignment.width >= field.attributedStringValue.size().width,
                "\(localeID): \(text) fits its text alignment rectangle")
            #expect(
                abs(alignment.minX - (content.bounds.maxX - alignment.maxX)) <= 1,
                "\(localeID): \(text) keeps equal horizontal text padding")
        }
    }
}

/// The Mac grid host's part of the scroll date label (#777): what it reports as the person's scrolling, when it
/// hides the label, where it puts it beside the native scroller knob, and that the label ends with the host.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalGridScrollDateLabelTests {
    private static let count = 3_000

    // MARK: - Movement

    @Test func onlyNavigationCommandsAreJumpsAndTheHostsOtherMovesAreItsOwn() throws {
        let fixture = try Fixture()
        let host = fixture.host
        let recorder = MovementRecorder(fixture: fixture)

        let jumps: [(String, () -> Void)] = [
            ("scrubber jump", { host.scrollToFlatIndex(900) }),
            ("photo jump", { host.scrollToItem(Fixture.uid(2_000)) }),
            ("newest photos", { host.scrollToBottom() }),
        ]
        for (name, jump) in jumps {
            let movements = recorder.record(name, jump)
            #expect(movements.contains { $0.isJump }, "\(name) is a navigation jump")
            #expect(movements.allSatisfy { $0.isHostDriven || $0.isLayout }, "\(name) is not the person's scroll")
        }

        let restore = GridScrollAnchor(itemID: Fixture.uid(600), topOffset: 40)
        let ownMoves: [(String, () -> Void)] = [
            ("restore", { host.requestInitialViewport(.restore(restore)) }),
            (
                "resize settle",
                {
                    fixture.window.setContentSize(NSSize(width: 640, height: 600))
                    host.layoutSubtreeIfNeeded()
                }
            ),
            ("zoom step", { host.setLevel(host.coordinator.level - 1) }),
        ]
        for (name, move) in ownMoves {
            let movements = recorder.record(name, move)
            #expect(
                movements.allSatisfy { ($0.isHostDriven || $0.isLayout) && !$0.isJump },
                "\(name) is the host's own move, not a navigation jump")
        }

        // A jump during a live scroll stays the host's jump.
        fixture.beginLiveScroll()
        let duringLive = recorder.record("jump during a live scroll") { host.scrollToFlatIndex(100) }
        #expect(duringLive.allSatisfy { $0.isHostDriven && $0.isJump })

        // The scroll view moves the clip during a live scroll (trackpad, momentum, scroller knob).
        let live = recorder.record("live scroll") { fixture.scrollClip(by: 300) }
        #expect(live.last?.isTracking == true)
        #expect(live.last?.isHostDriven == false)
        fixture.endLiveScroll()

        // Without a live scroll, a clip change carries no input flag; the shared classifier then counts it only as a
        // continuous movement. A classic mouse wheel scrolls this way: AppKit animates its steps after the event.
        let plain = try #require(recorder.record("plain move") { fixture.scrollClip(by: 300) }.last)
        #expect(!plain.isHostDriven && !plain.isTracking && !plain.isDragging && !plain.isLayout && !plain.isJump)
    }

    /// A classic mouse wheel starts no live scroll, and AppKit animates its steps after the event. Its continuous
    /// steps still count as the person's scrolling.
    @Test func continuousUnbracketedStepsShowTheLabel() async throws {
        let clock = StepClock()
        let fixture = try Fixture(presenter: clock.presenter())
        let label = try await fixture.enabledLabel()
        for _ in 0..<6 {
            clock.advance(0.01)
            fixture.scrollClip(by: 300)
        }
        #expect(label.controller.presentation.isVisible, "continuous wheel steps show the label")
    }

    /// A navigation jump ends a label that wheel steps showed, and one step right after it is not a continuous
    /// movement yet. Layout or the host's own moves would leave the label visible.
    @Test func aJumpEndsAVisibleLabelAndOneStepAfterItShowsNothing() async throws {
        let clock = StepClock()
        let fixture = try Fixture(presenter: clock.presenter())
        let label = try await fixture.enabledLabel()
        for _ in 0..<6 {
            clock.advance(0.01)
            fixture.scrollClip(by: 300)
        }
        try #require(label.controller.presentation.isVisible, "SETUP: wheel steps show the label")
        fixture.host.scrollToFlatIndex(200)
        #expect(!label.controller.presentation.isVisible, "a navigation jump ends the label")
        clock.advance(0.01)
        fixture.scrollClip(by: 300)
        #expect(!label.controller.presentation.isVisible, "one step after a jump shows nothing")
        for _ in 0..<5 {
            clock.advance(0.01)
            fixture.scrollClip(by: 300)
        }
        #expect(label.controller.presentation.isVisible, "CONTROL: continuous steps after it count")
    }

    /// AppKit moves the clip itself while the window changes size without a live resize: the zoom button, a
    /// title-bar double-click, full screen or tiling. At the newest edge, where the grid opens, that is layout.
    /// The person has scrolled there, so the host no longer pins the bottom and makes no move of its own.
    @Test func aWindowResizeAtTheNewestEdgeShowsNoLabel() async throws {
        let clock = StepClock()
        let fixture = try Fixture(startsAtNewest: true, presenter: clock.presenter())
        let label = try await fixture.enabledLabel()
        fixture.beginLiveScroll()
        fixture.endLiveScroll()
        #expect(abs(fixture.clipView.bounds.origin.y - fixture.maxScrollY) <= 1, "SETUP: at the newest edge")
        let recorder = MovementRecorder(fixture: fixture)
        let movements = recorder.record("window resize") {
            for step in 1...8 {
                clock.advance(0.01)
                fixture.window.setContentSize(NSSize(width: 800, height: 600 + CGFloat(step) * 40))
                fixture.host.layoutSubtreeIfNeeded()
            }
        }
        #expect(!fixture.host.inLiveResize, "SETUP: no live resize")
        #expect(
            movements.allSatisfy { $0.isLayout && !$0.isHostDriven },
            "the clip moves of a resize are layout: \(movements.map { ($0.isLayout, $0.isHostDriven) })")
        #expect(!label.controller.presentation.isVisible, "a window resize shows no label")
    }

    // MARK: - Show and hide

    @Test func aBriskLiveScrollShowsTheLabelBesideTheScrollerBelowTheToolbar() async throws {
        let fixture = try Fixture(toolbar: 52)
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible)
        let months = try #require(TimelineScrollDateIndex.build(items: fixture.items, revision: 1))
        #expect(label.controller.presentation.text == months.month(containing: 1_300)?.text)
        #expect(!label.view.isHidden && label.overlay.alphaValue == 1)
        let frame = label.view.frame
        let width = label.overlay.bounds.width
        #expect(abs(frame.maxX - (width - TimelineScrollDateLabelMotion.indicatorGap)) <= 1, "beside the scroller")
        #expect(frame.minY >= 52, "never under the toolbar")
        #expect(frame.maxY <= label.overlay.bounds.height)
    }

    @Test func momentumKeepsTheLabelAndTheLingerHidesItAfterTheScrollStops() async throws {
        var tuning = TimelineScrollDateLabelPolicy.Tuning.standard
        tuning.linger = 0.5
        let fixture = try Fixture(
            presenter: MetalGridScrollDateLabelPresenter(controller: TimelineScrollDateLabelController(tuning: tuning)))
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")

        // Momentum: about 1,000 points per second for twice the linger.
        let momentumEnd = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < momentumEnd {
            fixture.scrollClip(by: 10)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(label.controller.presentation.isVisible, "momentum keeps the label")
        fixture.endLiveScroll()

        let deadline = ContinuousClock.now + .seconds(5)
        while label.controller.presentation.isVisible, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!label.controller.presentation.isVisible, "the linger ends after the scroll stops")
        #expect(label.view.isHidden, "Reduce Motion: no fade")
    }

    @Test func aSlowLiveScrollShowsNoLabel() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        fixture.beginLiveScroll()
        for _ in 0..<8 {
            fixture.scrollClip(by: 1)  // About 200 points per second: inspection scrolling.
            try await Task.sleep(for: .milliseconds(5))
        }
        fixture.endLiveScroll()
        #expect(!label.controller.presentation.isVisible, "slow scrolling")
    }

    @Test func jumpsRestoresZoomStepsAndResizeSettlesShowNoLabel() async throws {
        let fixture = try Fixture()
        let host = fixture.host
        let label = try await fixture.enabledLabel()
        let restore = GridScrollAnchor(itemID: Fixture.uid(40), topOffset: 0)
        let moves: [(String, () -> Void)] = [
            ("scrubber jumps", { for index in [2_800, 100, 1_500, 2_000] { host.scrollToFlatIndex(index) } }),
            ("photo jumps", { for index in [2_900, 50, 1_700] { host.scrollToItem(Fixture.uid(index)) } }),
            ("newest photos", { host.scrollToBottom() }),
            ("restore", { host.requestInitialViewport(.restore(restore)) }),
            (
                "resize settle",
                {
                    fixture.window.setContentSize(NSSize(width: 600, height: 560))
                    host.layoutSubtreeIfNeeded()
                }
            ),
            ("zoom step", { host.setLevel(host.coordinator.level + 1) }),
        ]
        for (name, move) in moves {
            for _ in 0..<3 {
                move()
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!label.controller.presentation.isVisible, "\(name) shows no label")
        }
    }

    /// A flick shows the label; a scrubber jump within its linger fades it out at once instead of keeping a month
    /// beside the scrubber's own date pill.
    @Test func aScrubberJumpEndsAVisibleLabel() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        fixture.endLiveScroll()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")
        fixture.host.scrollToFlatIndex(200)
        #expect(!label.controller.presentation.isVisible, "the jump ends the label")
    }

    @Test func aZoomHidesTheLabelAtOnce() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")
        fixture.host.setLevel(fixture.host.coordinator.level - 1)
        #expect(!label.controller.presentation.isVisible)
        #expect(label.view.isHidden, "no fade during a zoom")
        #expect(fixture.host.scrollDateLabelHostState().isTransforming)
    }

    @Test func aPinchHidesTheLabelAtOnce() async throws {
        let fixture = try Fixture()
        let host = fixture.host
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")
        let clip = fixture.clipView.bounds
        host.coordinator.beginLiveZoom(
            cursorContentPoint: CGPoint(x: clip.midX, y: clip.midY), viewportPoint: CGPoint(x: clip.midX, y: 300))
        try #require(host.coordinator.isZoomingLive, "SETUP: the live zoom of a pinch runs")
        host.step()  // The next display tick sees the pinch.
        #expect(host.scrollDateLabelHostState().isTransforming)
        #expect(!label.controller.presentation.isVisible)
        #expect(label.view.isHidden, "no fade during a pinch")
    }

    @Test func aLiveWindowResizeHidesTheLabelAtOnce() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: fixture.window)
        #expect(!label.controller.presentation.isVisible)
        #expect(label.view.isHidden, "no fade during a live resize")
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: fixture.window)
    }

    @Test func leavingTheWindowHidesTheLabelAtOnce() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")
        fixture.window.contentView = nil
        #expect(!fixture.host.scrollDateLabelHostState().hasWindow)
        #expect(!label.controller.presentation.isVisible)
        #expect(label.view.isHidden)
    }

    @Test func anOccludedWindowHidesTheLabelAtOnce() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")
        fixture.window.testOcclusionState = []
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: fixture.window)
        #expect(!fixture.host.scrollDateLabelHostState().isActive)
        #expect(!label.controller.presentation.isVisible)
        #expect(label.view.isHidden)
    }

    @Test func contentThatDoesNotScrollOrHasNoPhotosKeepsTheLabelOff() throws {
        let fixture = try Fixture(count: 12)
        let host = fixture.host
        #expect(!host.scrollDateLabelHostState().isScrollable, "twelve photos fit the window")
        #expect(host.scrollDateLabelHostState().suppressesLabel)
        host.setDataSource(StubMetalGridDataSource(count: 0, volumeID: Fixture.volume))
        #expect(!host.scrollDateLabelHostState().hasItems)
    }

    @Test func turningTheLabelOffHidesItAndStopsTheAnchorLookup() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")
        fixture.host.setScrollDateLabelEnabled(false)
        #expect(!label.controller.presentation.isVisible)
        #expect(fixture.host.coordinator.onTopVisibleIndexChange == nil, "no per-frame lookup while off")
    }

    // MARK: - Lists and routes

    @Test func anotherListDropsItsMonthsAtOnceAndARefreshKeepsThem() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let coordinator = fixture.productionCoordinator(listID: "library")
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")

        coordinator.receiveContent(
            items: fixture.items, revision: 2, routeGeneration: 0, listID: "library", initialViewport: .preserve,
            markers: [], makeSource: { StubMetalGridDataSource(count: Self.count, volumeID: Fixture.volume) })
        #expect(label.controller.index != nil, "a refresh keeps the months while the new ones build")
        #expect(label.controller.presentation.isVisible, "a refresh does not hide the label")

        coordinator.receiveContent(
            items: fixture.items, revision: 3, routeGeneration: 0, listID: "search", initialViewport: .preserve,
            markers: [], makeSource: { StubMetalGridDataSource(count: Self.count, volumeID: Fixture.volume) })
        #expect(label.controller.index == nil, "no month of the old list")
        #expect(!label.controller.presentation.isVisible)
        #expect(label.view.isHidden, "hidden at once")
    }

    @Test func aRouteChangeDropsTheMonthsAtOnce() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let coordinator = fixture.productionCoordinator(listID: "library")
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")
        coordinator.receiveContent(
            items: fixture.items, revision: 2, routeGeneration: 1, listID: "library", initialViewport: .newest,
            markers: [], makeSource: { StubMetalGridDataSource(count: Self.count, volumeID: Fixture.volume) })
        #expect(label.controller.index == nil, "no month of the old route")
        #expect(label.view.isHidden, "hidden at once")
    }

    @Test func openingAPhotoHidesTheLabelAtOnce() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let coordinator = fixture.productionCoordinator(listID: "library")
        var opened: PhotoUID?
        coordinator.onOpen = { item, _ in opened = item.uid }
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")
        coordinator.openPhoto(Fixture.uid(1_300))
        #expect(opened == Fixture.uid(1_300))
        #expect(!label.controller.presentation.isVisible)
        #expect(label.view.isHidden, "hidden before the viewer covers the grid")
    }

    // MARK: - Placement

    /// The label centres on the actual native knob, converted into the host, at several scroll positions.
    @Test func theLabelCentresOnTheNativeKnob() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")
        var centres: [CGFloat] = []
        for fraction in [0.25, 0.5, 0.75] as [CGFloat] {
            fixture.scrollClip(toY: (fixture.maxScrollY * fraction).rounded())
            try await Task.sleep(for: .milliseconds(5))
            #expect(label.controller.presentation.isVisible, "SETUP: still visible at \(fraction)")
            let knob = try #require(fixture.knobRectInOverlay(of: label), "SETUP: the scroller has a knob")
            #expect(knob.height > 0)
            #expect(abs(label.view.frame.midY - knob.midY) <= 0.5, "centred on the knob at \(fraction)")
            centres.append(label.view.frame.midY)
        }
        #expect(centres[0] < centres[1] && centres[1] < centres[2], "the label follows the knob")
    }

    @Test func theKnobUnderTheToolbarClampsTheLabelBelowIt() async throws {
        let fixture = try Fixture(toolbar: 52)
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        fixture.scrollClip(toY: 0)
        #expect(label.controller.presentation.isVisible, "SETUP: still visible at the top")
        let knob = try #require(fixture.knobRectInOverlay(of: label))
        #expect(knob.midY < 52, "SETUP: the knob sits under the toolbar")
        #expect(abs(label.view.frame.minY - 52) <= 0.5, "the label rests right below the toolbar")
    }

    @Test func theLabelStaysLeftOfTheDateScrubber() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        label.setTrailingInset(TimelineDateScrubber.dormantTrailingReservation)
        let width = label.overlay.bounds.width
        let expectedMaxX =
            width - TimelineDateScrubber.dormantTrailingReservation - TimelineScrollDateLabelMotion.indicatorGap
        #expect(abs(label.view.frame.maxX - expectedMaxX) <= 1)
    }

    @Test func aMissingKnobHidesTheLabel() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        #expect(label.overlay.alphaValue == 1, "SETUP: placed beside the knob")
        fixture.scrollView.hasVerticalScroller = false
        fixture.layoutHost()
        #expect(label.overlay.alphaValue == 0, "no knob, no label")
        fixture.scrollView.hasVerticalScroller = true
        fixture.layoutHost()
        fixture.scrollClip(by: 300)
        #expect(label.overlay.alphaValue == 1, "the knob returns, the label returns")
    }

    /// Scroller insets move the knob when the scroll view tiles, without a clip change; the label follows.
    @Test func theLabelFollowsTheKnobWhenTheScrollViewTiles() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")
        let before = try #require(fixture.knobRectInOverlay(of: label))
        fixture.scrollView.scrollerInsets = NSEdgeInsets(top: 240, left: 0, bottom: 0, right: 0)
        fixture.scrollView.tile()
        let knob = try #require(fixture.knobRectInOverlay(of: label))
        #expect(abs(knob.midY - before.midY) > 2, "SETUP: the knob moved")
        #expect(abs(label.view.frame.midY - knob.midY) <= 0.5, "the label follows the tiled knob")
    }

    // MARK: - Anchor

    @Test func theFramePathReportsTheTopPhotoRowBelowTheToolbar() throws {
        let fixture = try Fixture(toolbar: 52)
        let host = fixture.host
        var reported: [Int?] = []
        host.coordinator.onTopVisibleIndexChange = { reported.append($0) }
        host.scrollToFlatIndex(900)
        host.step()
        let top = try #require(reported.last ?? nil, "the frame reports an anchor")
        let rect = try #require(host.coordinator.cellContentRect(forFlatIndex: top))
        let originY = fixture.clipView.bounds.origin.y
        #expect(rect.minY >= originY + 52 - 0.5, "the anchor row starts below the toolbar")
        let count = reported.count
        host.scrollToFlatIndex(900)  // The same place: a new frame, the same anchor.
        host.step()
        #expect(reported.count == count, "an unchanged anchor is not reported again")
    }

    // MARK: - View and lifetime

    @Test func reduceMotionShowsAndHidesWithoutAFade() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel(reduceMotion: false)
        try await fixture.scrollUntilShown()
        #expect(label.controller.presentation.fadeDuration != nil, "SETUP: a normal show fades")
        #expect(label.view.layer?.animationKeys()?.isEmpty == false, "SETUP: the fade runs")

        label.setReduceMotion(true)
        #expect(label.view.layer?.animationKeys()?.isEmpty ?? true, "Reduce Motion stops the fade")
        #expect(label.view.alphaValue == 1 && !label.view.isHidden)
        fixture.host.scrollToFlatIndex(200)
        #expect(label.view.isHidden, "Reduce Motion hides at once")
        try await fixture.flick()
        #expect(!label.view.isHidden && label.view.alphaValue == 1, "Reduce Motion shows at once")
        #expect(label.view.layer?.animationKeys()?.isEmpty ?? true, "no fade")
    }

    @Test func theLabelTakesNoClicksIsNoAccessibilityElementAndFollowsTheSystemAppearance() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        let center = NSPoint(x: label.view.frame.midX, y: label.view.frame.midY)
        #expect(label.overlay.hitTest(center) == nil)
        #expect(label.view.hitTest(center) == nil)
        let windowPoint = label.overlay.convert(center, to: nil)
        let hit = fixture.window.contentView?.hitTest(fixture.window.contentView!.convert(windowPoint, from: nil))
        #expect(hit !== label.view && hit !== label.overlay, "clicks reach the grid")
        #expect(!label.view.isAccessibilityElement())
        #expect(label.view.accessibilityChildren()?.isEmpty == true)
        #expect(label.view.appearance == nil && label.overlay.appearance == nil, "the system appearance applies")
    }

    @Test func dismantlingTheGridRetiresTheLabel() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        MetalProductionGridView.dismantleNSView(fixture.host, coordinator: MetalProductionGridView.Coordinator())
        #expect(label.controller.isRetired)
        #expect(fixture.host.coordinator.onTopVisibleIndexChange == nil, "no anchor callback outlives the host")
        #expect(fixture.scrollView.onScrollersReflected == nil, "no scroller callback outlives the host")
        try await fixture.flick()
        #expect(!label.controller.presentation.isVisible)
        #expect(label.view.isHidden)
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        static let volume = "label"
        let host: MetalGridScrollHost
        let window = VisibilityWindow()
        let items: [PhotoItem]
        let label: MetalGridScrollDateLabelPresenter

        init(
            toolbar: CGFloat = 0, count: Int = MetalGridScrollDateLabelTests.count, startsAtNewest: Bool = false,
            presenter: MetalGridScrollDateLabelPresenter? = nil
        ) throws {
            _ = NSApplication.shared
            let device = try #require(MTLCreateSystemDefaultDevice())
            host = try #require(
                MetalGridScrollHost(
                    device: device, dataSource: StubMetalGridDataSource(count: count, volumeID: Self.volume),
                    gridProfile: .testRegularTimeline))
            host.topBarInset = toolbar
            let calendar = Calendar(identifier: .gregorian)
            // 300 photos per month, oldest first: January to October 2026.
            items = (0..<count).map {
                PhotoItem(
                    uid: Fixture.uid($0),
                    captureTime: calendar.date(from: DateComponents(year: 2026, month: 1 + $0 / 300, day: 3))!,
                    mediaType: "image/jpeg")
            }
            window.testOcclusionState = [.visible]
            window.contentView = host
            label = presenter ?? MetalGridScrollDateLabelPresenter()
            host.installScrollDateLabel(label)
            host.layoutSubtreeIfNeeded()
            // A photo of May 2026 near the top, unless the grid stays at the newest edge where it opens.
            if !startsAtNewest, count > 1_300 { host.scrollToFlatIndex(1_300) }
        }

        deinit {
            MainActor.assumeIsolated { window.contentView = nil }
        }

        static func uid(_ index: Int) -> PhotoUID { PhotoUID(volumeID: volume, nodeID: "\(index)") }

        var clipView: NSClipView { host.coordinator.clipView! }
        var scrollView: MetalGridBlockingScrollView { clipView.superview as! MetalGridBlockingScrollView }
        var maxScrollY: CGFloat { max(0, (scrollView.documentView?.frame.height ?? 0) - clipView.bounds.height) }

        /// The label, turned on with the fixture's photos and their months built.
        func enabledLabel(reduceMotion: Bool = true) async throws -> MetalGridScrollDateLabelPresenter {
            label.setReduceMotion(reduceMotion)
            label.contentChanged(items, replacesList: true)
            host.setScrollDateLabelEnabled(true)
            let deadline = ContinuousClock.now + .seconds(10)
            while label.controller.index == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(label.controller.index != nil, "SETUP: the months are built")
            label.setAnchor(flatIndex: 1_300)  // The frame path reports it while the window draws.
            return label
        }

        /// A production grid coordinator that owns this host and shows the fixture's photos as one list.
        func productionCoordinator(listID: AnyHashable) -> MetalProductionGridView.Coordinator {
            let coordinator = MetalProductionGridView.Coordinator()
            coordinator.host = host
            coordinator.allItems = items
            coordinator.dataRevision = 1
            coordinator.scrollDateLabelListID = listID
            return coordinator
        }

        /// Starts a live scroll and returns right after the step that showed the label, with no wait in between.
        func scrollUntilShown() async throws {
            beginLiveScroll()
            for _ in 0..<20 {
                scrollClip(by: 300)
                if label.controller.presentation.isVisible { return }
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        /// A brisk trackpad scroll: six steps of 300 points, 5 ms apart. The live scroll stays open.
        func flick() async throws {
            beginLiveScroll()
            for _ in 0..<6 {
                scrollClip(by: 300)
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        func beginLiveScroll() {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        }

        func endLiveScroll() {
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        }

        /// Moves the clip as the scroll view does for the person's input, within the content.
        func scrollClip(by delta: CGFloat) {
            scrollClip(toY: clipView.bounds.origin.y + delta)
        }

        func scrollClip(toY y: CGFloat) {
            clipView.scroll(to: CGPoint(x: 0, y: min(max(0, y), maxScrollY)))
            scrollView.reflectScrolledClipView(clipView)
        }

        func layoutHost() {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
        }

        /// The native knob in the label overlay, through window coordinates.
        func knobRectInOverlay(of label: MetalGridScrollDateLabelPresenter) -> CGRect? {
            guard let scroller = scrollView.verticalScroller, !scroller.isHidden else { return nil }
            let inWindow = scroller.convert(scroller.rect(for: .knob), to: nil)
            return label.overlay.convert(inWindow, from: nil)
        }
    }

    /// A label clock that moves only when a test advances it, so continuous steps never depend on machine load.
    private final class StepClock: @unchecked Sendable {
        private(set) var time: TimeInterval = 1_000

        func advance(_ seconds: TimeInterval) { time += seconds }

        /// A presenter whose label reads this clock. Its hide waits far beyond any test.
        @MainActor
        func presenter() -> MetalGridScrollDateLabelPresenter {
            let clock = TimelineScrollDateLabelClock(
                now: { [self] in time }, sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
            return MetalGridScrollDateLabelPresenter(controller: TimelineScrollDateLabelController(clock: clock))
        }
    }

    /// Records the movement the host reports for each clip change, observed where the host observes it.
    @MainActor
    private final class MovementRecorder {
        private let host: MetalGridScrollHost
        private var movements: [TimelineScrollDateLabelMovement] = []
        private var observer: (any NSObjectProtocol)?

        init(fixture: Fixture) {
            host = fixture.host
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: fixture.clipView, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.movements.append(self.host.scrollDateLabelMovement)
                }
            }
        }

        deinit {
            MainActor.assumeIsolated {
                if let observer { NotificationCenter.default.removeObserver(observer) }
            }
        }

        func record(_ name: String, _ action: () -> Void) -> [TimelineScrollDateLabelMovement] {
            movements.removeAll()
            action()
            #expect(!movements.isEmpty, "SETUP: \(name) moves the viewport")
            return movements
        }
    }
}
