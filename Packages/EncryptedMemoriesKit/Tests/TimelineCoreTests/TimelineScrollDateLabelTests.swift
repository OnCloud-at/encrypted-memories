import CoreGraphics
import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

private func scrollDateIndexItems(_ count: Int) -> [PhotoItem] {
    (0..<count).map {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "n\($0)"),
            captureTime: Date(timeIntervalSince1970: 1_780_000_000 + Double($0) * 86_400), mediaType: "image/jpeg")
    }
}

private func scrollDateMovementClassifier() -> (TimelineScrollDateLabelMovement, TimeInterval) -> Bool {
    var classifier = TimelineScrollDateLabelInputClassifier()
    return { classifier.isUserMovement($0, at: $1) }
}

private func scrollDateMovementFixture(
    programmatic: Bool = false, host: Bool = false, system: Bool = false, dragging: Bool = false,
    animating: Bool, applyingJump: Bool = false, layout: Bool = false
) -> TimelineScrollDateLabelMovement {
    .observed(
        isApplyingProgrammaticScroll: programmatic, hostAnimationActive: host, systemJumpActive: system,
        isLayout: layout, isTracking: false, isDragging: dragging, isDecelerating: false,
        isScrollAnimating: animating, isApplyingJump: applyingJump)
}

/// Feeds the same injected-clock movement to controller and platform-session tests.
@MainActor
@discardableResult
private func flickScrollDateLabel(
    _ controller: TimelineScrollDateLabelController, _ manual: ManualClock, frames: Int = 12,
    speed: Double = 2_000, from initialOffset: Double = 0
) -> Double {
    var offset = initialOffset
    for _ in 0..<frames {
        controller.userMoved(offsetY: offset)
        manual.advance(by: 1 / 120)
        offset += speed / 120
    }
    return offset
}

/// Behavior of the transient scroll date label: visibility policy, controller lifecycle, month lookup and placement.
@Suite struct TimelineScrollDateLabelPolicyTests {
    /// Feeds user movement at `speed` points per second for `duration` seconds at `rate` frames per second.
    private func scroll(
        _ policy: inout TimelineScrollDateLabelPolicy, from start: TimeInterval, offset: inout Double,
        speed: Double, duration: TimeInterval, rate: Double = 120
    ) -> TimeInterval {
        let step = 1 / rate
        var time = start
        policy.userMoved(offsetY: offset, at: time)
        while time < start + duration - step / 2 {
            time += step
            offset += speed * step
            policy.userMoved(offsetY: offset, at: time)
        }
        return time
    }

    @Test func slowInspectionScrollingNeverShowsTheLabel() {
        var policy = TimelineScrollDateLabelPolicy()
        var offset = 0.0
        _ = scroll(&policy, from: 0, offset: &offset, speed: 350, duration: 3)
        #expect(!policy.isVisible)
    }

    @Test func briskDragShowsTheLabelWhileTheFingerStillMoves() {
        var policy = TimelineScrollDateLabelPolicy()
        var offset = 0.0
        // 1,500 pt/s is an ordinary brisk drag. The label must be visible within the first 50 ms.
        _ = scroll(&policy, from: 0, offset: &offset, speed: 1_500, duration: 0.05)
        #expect(policy.isVisible)
        // The same holds at 60 frames per second.
        var slowDisplay = TimelineScrollDateLabelPolicy()
        offset = 0
        _ = scroll(&slowDisplay, from: 0, offset: &offset, speed: 1_500, duration: 0.05, rate: 60)
        #expect(slowDisplay.isVisible)
    }

    @Test func momentumKeepsTheLabelAndItHidesAboutOneSecondAfterTheStop() {
        var policy = TimelineScrollDateLabelPolicy()
        var offset = 0.0
        var time = scroll(&policy, from: 0, offset: &offset, speed: 2_000, duration: 0.2)
        #expect(policy.isVisible)
        // Momentum: the speed decays from 2,000 pt/s over about 1.5 s.
        var speed = 2_000.0
        while speed > 20 {
            time += 1 / 120
            speed *= 0.97
            offset += speed / 120
            policy.userMoved(offsetY: offset, at: time)
            policy.tick(at: time)
            #expect(policy.isVisible || speed < policy.tuning.sustainSpeed, "momentum above the sustain speed keeps it")
        }
        let stop = time
        let hidEarly = policy.tick(at: stop + 0.5)
        #expect(!hidEarly)
        #expect(policy.isVisible)
        let deadline = try! #require(policy.hideDeadline)
        #expect(deadline > stop - 1 && deadline <= stop + 1)
        let hidAtDeadline = policy.tick(at: deadline)
        #expect(hidAtDeadline)
        #expect(!policy.isVisible)
    }

    @Test func stopAndRestartNearTheThresholdDoesNotFlicker() {
        var policy = TimelineScrollDateLabelPolicy()
        var offset = 0.0
        var time = scroll(&policy, from: 0, offset: &offset, speed: 900, duration: 0.2)
        #expect(policy.isVisible)
        // Alternate between just below the show speed and a short rest, each shorter than the linger time.
        for _ in 0..<6 {
            time = scroll(&policy, from: time + 0.4, offset: &offset, speed: 550, duration: 0.3)
            let hid = policy.tick(at: time)
            #expect(!hid)
            #expect(policy.isVisible, "a restart within the linger time keeps the label")
        }
        // After it hides, the same near-threshold speed does not bring it back.
        policy.tick(at: time + 2)
        #expect(!policy.isVisible)
        _ = scroll(&policy, from: time + 2.1, offset: &offset, speed: 550, duration: 0.5)
        #expect(!policy.isVisible)
    }

    @Test func programmaticPlacementLayoutAndResizeNeverShowTheLabel() {
        var policy = TimelineScrollDateLabelPolicy()
        policy.userMoved(offsetY: 0, at: 0)
        policy.nonUserMoved()  // A placement of 50,000 pt must not count as speed.
        policy.userMoved(offsetY: 50_000, at: 0.01)
        #expect(!policy.isVisible)
        policy.userMoved(offsetY: 50_001, at: 0.02)
        #expect(!policy.isVisible)
    }

    @Test func nonJumpProgrammaticMovementKeepsTheCurrentLinger() {
        var policy = TimelineScrollDateLabelPolicy()
        var offset = 0.0
        _ = scroll(&policy, from: 0, offset: &offset, speed: 2_000, duration: 0.1)
        let deadline = policy.hideDeadline
        policy.nonUserMoved()  // Layout, resize, or a content-driven viewport adjustment.
        #expect(policy.isVisible)
        #expect(policy.hideDeadline == deadline)
        policy.userMoved(offsetY: 50_000, at: 0.2)
        policy.userMoved(offsetY: 50_000, at: 0.21)
        #expect(policy.hideDeadline == deadline, "stationary movement after layout does not extend the linger")
    }

    @Test func aMarkedJumpClearsTheLingerWithoutSuppressingThePolicy() {
        var policy = TimelineScrollDateLabelPolicy()
        var offset = 0.0
        _ = scroll(&policy, from: 0, offset: &offset, speed: 2_000, duration: 0.1)
        #expect(policy.isVisible, "SETUP: the flick shows the label")
        policy.nonUserMoved(isJump: true)
        #expect(!policy.isVisible)
        #expect(policy.hideDeadline == nil)
        #expect(!policy.isSuppressed, "a jump is not pinch or route suppression")
        _ = scroll(&policy, from: 0.2, offset: &offset, speed: 200, duration: 0.1)
        #expect(!policy.isVisible, "inspection scrolling still needs the normal show threshold")
        _ = scroll(&policy, from: 0.4, offset: &offset, speed: 2_000, duration: 0.1)
        #expect(policy.isVisible, "a later brisk drag shows the label again")
    }

    @Test func aMarkedJumpFromHiddenKeepsThePolicyHidden() {
        var policy = TimelineScrollDateLabelPolicy()
        policy.nonUserMoved(isJump: true)
        #expect(!policy.isVisible)
        #expect(policy.hideDeadline == nil)
    }

    @Test func pinchSuppressesTheLabelUntilResumed() {
        var policy = TimelineScrollDateLabelPolicy()
        var offset = 0.0
        var time = scroll(&policy, from: 0, offset: &offset, speed: 2_000, duration: 0.1)
        #expect(policy.isVisible)
        policy.suppress()
        #expect(!policy.isVisible)
        #expect(policy.hideDeadline == nil)
        time = scroll(&policy, from: time, offset: &offset, speed: 3_000, duration: 0.2)
        #expect(!policy.isVisible, "movement during a pinch never shows the label")
        policy.resume()
        _ = scroll(&policy, from: time + 0.1, offset: &offset, speed: 3_000, duration: 0.1)
        #expect(policy.isVisible)
    }

    @Test func aLongPauseStartsANewMeasurement() {
        var policy = TimelineScrollDateLabelPolicy()
        policy.userMoved(offsetY: 0, at: 0)
        // 300 pt in one sample after a 2 s pause is a slow scroll, not a 36,000 pt/s spike.
        policy.userMoved(offsetY: 300, at: 2)
        #expect(!policy.isVisible)
    }
}

@Suite struct TimelineScrollDateIndexTests {
    private func item(_ i: Int, _ y: Int, _ m: Int, _ d: Int) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "n\(i)"),
            captureTime: timelineTestUTCCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!,
            mediaType: "image/jpeg")
    }

    private func makeIndex(_ items: [PhotoItem], locale: String = "en_US") -> TimelineScrollDateIndex? {
        TimelineScrollDateIndex.build(
            items: items, revision: 7, calendar: timelineTestUTCCalendar, locale: Locale(identifier: locale))
    }

    @Test func mixedMonthViewportUsesTheMonthOfTheAnchorPhoto() throws {
        // One viewport of 12 photos spans three months.
        let items =
            (0..<4).map { item($0, 2026, 1, 28 + $0 % 3) } + (4..<8).map { item($0, 2026, 2, $0) }
            + (8..<12).map { item($0, 2026, 3, $0) }
        let index = try #require(makeIndex(items))
        #expect(index.month(containing: 0)?.text == "January 2026")
        #expect(index.month(containing: 3)?.text == "January 2026")
        #expect(index.month(containing: 4)?.text == "February 2026")
        #expect(index.month(containing: 11)?.text == "March 2026")
        #expect(index.month(containing: 5)?.range == 4..<8)
        #expect(index.revision == 7)
    }

    @Test func monthBoundaryAndYearBoundaryInDescendingOrder() throws {
        let items = [item(0, 2026, 1, 2), item(1, 2026, 1, 1), item(2, 2025, 12, 31), item(3, 2025, 12, 30)]
        let index = try #require(makeIndex(items, locale: "de_AT"))
        #expect(index.month(containing: 1)?.text == "Jänner 2026")
        #expect(index.month(containing: 2)?.text == "Dezember 2025")
        #expect(index.month(containing: 2)?.range == 2..<4)
    }

    @Test func singleMonthAndShortListsKeepTheLabel() throws {
        let single = try #require(makeIndex((0..<500).map { item($0, 2026, 6, 1 + $0 % 28) }))
        #expect(single.month(containing: 0)?.range == 0..<500)
        #expect(single.month(containing: 499)?.text == "June 2026")
        let short = try #require(makeIndex([item(0, 2026, 6, 1)]))
        #expect(short.month(containing: 0)?.text == "June 2026")
        #expect(short.month(containing: 1) == nil)
        #expect(short.month(containing: -1) == nil)
        #expect(makeIndex([]) == nil)
    }

    @Test func oneUnusableDateKeepsEveryOtherMonth() throws {
        let unusable = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "nan"), captureTime: Date(timeIntervalSinceReferenceDate: .nan),
            mediaType: "image/jpeg")
        let items = [unusable, item(1, 2026, 1, 5), item(2, 2026, 1, 6), unusable, item(4, 2026, 2, 1)]
        let index = try #require(makeIndex(items))
        #expect(index.month(containing: 0)?.text == "January 2026", "a leading unusable date joins the first month")
        #expect(index.month(containing: 3)?.text == "January 2026", "an inner unusable date joins its neighbor")
        #expect(index.month(containing: 4)?.text == "February 2026")
        #expect(makeIndex(Array(repeating: unusable, count: 3)) == nil)
    }

    @Test func calendarTimeZoneDecidesTheMonth() throws {
        // 23:30 UTC on 31 January is February in Vienna.
        let utc = timelineTestUTCCalendar
        var vienna = timelineTestUTCCalendar
        vienna.timeZone = TimeZone(identifier: "Europe/Vienna")!
        let date = utc.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 23, minute: 30))!
        let items = [PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "x"), captureTime: date, mediaType: "image/jpeg")]
        let inUTC = try #require(
            TimelineScrollDateIndex.build(items: items, revision: 1, calendar: utc, locale: Locale(identifier: "en_US"))
        )
        let inVienna = try #require(
            TimelineScrollDateIndex.build(
                items: items, revision: 1, calendar: vienna, locale: Locale(identifier: "en_US")))
        #expect(inUTC.month(containing: 0)?.text == "January 2026")
        #expect(inVienna.month(containing: 0)?.text == "February 2026")
    }

    @Test func largeLibraryBuildsOnceWithinBudget() throws {
        // 200,000 photos over about 16 years, newest first.
        let start = timelineTestUTCCalendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let items = (0..<200_000).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "n\($0)"),
                captureTime: start.addingTimeInterval(Double(-$0) * 2_500),
                mediaType: "image/jpeg")
        }
        let clock = ContinuousClock()
        var built: TimelineScrollDateIndex?
        let elapsed = clock.measure {
            built = TimelineScrollDateIndex.build(
                items: items, revision: 1, calendar: timelineTestUTCCalendar, locale: Locale(identifier: "en_US"))
        }
        let index = try #require(built)
        #expect(index.starts.count > 180 && index.starts.count < 200)
        #expect(elapsed < .seconds(2), "build took \(elapsed)")
        // Every lookup agrees with the marker list.
        for (position, startIndex) in index.starts.enumerated() {
            #expect(index.month(containing: startIndex)?.text == index.texts[position])
        }
    }
}

/// Adapts the existing shared test clock to the label's absolute TimeInterval dependency.
private final class ManualClock: @unchecked Sendable {
    private let shared = TimelineRefreshTestClock()
    private let epoch: ContinuousClock.Instant

    init() { epoch = shared.now }

    var now: TimeInterval {
        let parts = epoch.duration(to: shared.now).components
        return 100 + Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    var waiterCount: Int { shared.pendingSleeps }

    var clock: TimelineScrollDateLabelClock {
        TimelineScrollDateLabelClock(
            now: { [self] in now },
            sleep: { [self] deadline in
                try await shared.dependency.sleepUntil(epoch.advanced(by: .seconds(deadline - 100)))
            })
    }

    func advance(by seconds: TimeInterval) { shared.advance(by: .seconds(seconds)) }
}

/// Lets queued main-actor tasks run. With a condition it waits until the condition holds or 5 s pass; without one it
/// lets other tasks run for 50 ms, so a test can show that nothing happens. A ContinuousClock deadline bounds both,
/// so a loaded machine cannot turn a fixed number of yields into a false failure.
@MainActor
private func settle(until condition: (() -> Bool)? = nil) async {
    let clock = ContinuousClock()
    let deadline = clock.now + (condition == nil ? .milliseconds(50) : .seconds(5))
    while clock.now < deadline {
        if let condition, condition() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
@Suite struct TimelineScrollDateLabelControllerTests {
    private func items() -> [PhotoItem] {
        (0..<40).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "n\($0)"),
                captureTime: timelineTestUTCCalendar.date(
                    from: DateComponents(year: 2026, month: 1 + $0 / 10, day: 2))!,
                mediaType: "image/jpeg")
        }
    }

    private func makeController(
        _ manual: ManualClock, tuning: TimelineScrollDateLabelPolicy.Tuning = .standard
    ) -> (TimelineScrollDateLabelController, Recorder) {
        let controller = TimelineScrollDateLabelController(clock: manual.clock, tuning: tuning)
        let recorder = Recorder()
        controller.onChange = { recorder.changes.append($0) }
        controller.setIndex(
            TimelineScrollDateIndex.build(
                items: items(), revision: 1, calendar: timelineTestUTCCalendar, locale: Locale(identifier: "en_US")))
        controller.setAnchor(flatIndex: 0)
        return (controller, recorder)
    }

    private final class Recorder {
        var changes: [TimelineScrollDateLabelController.Presentation] = []
    }

    @Test func crossingTheShowThresholdSlowlyUsesTheSlowFadeIn() {
        let manual = ManualClock()
        let (controller, recorder) = makeController(manual)
        flickScrollDateLabel(controller, manual, frames: 48, speed: 650)
        #expect(controller.presentation.isVisible, "SETUP: the slow crossing still shows the label")
        #expect(recorder.changes.first?.fadeDuration == 0.40)
    }

    @Test func aFastCrossingUsesTheFastFadeIn() {
        let manual = ManualClock()
        let (controller, recorder) = makeController(manual)
        flickScrollDateLabel(controller, manual, speed: 2_000)
        #expect(controller.presentation.isVisible)
        #expect(recorder.changes.first?.fadeDuration == 0.20)
    }

    @Test func aSlowStopUsesTheLastSustainingSpeedRatherThanThePeak() async {
        let manual = ManualClock()
        let (controller, _) = makeController(manual)
        let offset = flickScrollDateLabel(controller, manual)
        flickScrollDateLabel(controller, manual, frames: 60, speed: 80, from: offset)
        #expect(
            controller.policy.hideDeadline.map { $0 < manual.now + controller.policy.tuning.linger - 0.1 } == true,
            "the late slow samples no longer extend the linger")
        manual.advance(by: 2)
        await settle { !controller.presentation.isVisible }
        #expect(!controller.presentation.isVisible)
        #expect(controller.presentation.fadeDuration == 0.70)
    }

    @Test func aFastStopUsesTheFastFadeOut() async {
        let manual = ManualClock()
        let (controller, _) = makeController(manual)
        flickScrollDateLabel(controller, manual)
        manual.advance(by: 2)
        await settle { !controller.presentation.isVisible }
        #expect(!controller.presentation.isVisible)
        #expect(controller.presentation.fadeDuration == 0.35)
    }

    @Test(arguments: [649.999, 650.0, 650.001])
    func fadeClassificationIncludesTheFastBoundary(speed: Double) async {
        let manual = ManualClock()
        var tuning = TimelineScrollDateLabelPolicy.Tuning.standard
        tuning.smoothing = 0.001  // The one-second sample makes the EMA exactly equal the test speed.
        let (controller, _) = makeController(manual, tuning: tuning)
        controller.userMoved(offsetY: 0)
        manual.advance(by: 1)
        controller.userMoved(offsetY: speed)
        #expect(controller.presentation.isVisible)
        #expect(controller.presentation.fadeDuration == (speed >= tuning.fastFadeSpeed ? 0.20 : 0.40))
        manual.advance(by: 2)
        await settle { !controller.presentation.isVisible }
        #expect(controller.presentation.fadeDuration == (speed >= tuning.fastFadeSpeed ? 0.35 : 0.70))
    }

    @Test(arguments: [true, false])
    func fadeInAndFadeOutPairsAreIndependent(editFadeIn: Bool) async {
        var tuning = TimelineScrollDateLabelPolicy.Tuning.standard
        if editFadeIn {
            tuning.fadeIn.slow = 0.81
            tuning.fadeIn.fast = 0.23
        } else {
            tuning.fadeOut.slow = 0.91
            tuning.fadeOut.fast = 0.46
        }
        for slow in [true, false] {
            let manual = ManualClock()
            let (controller, _) = makeController(manual, tuning: tuning)
            flickScrollDateLabel(controller, manual, frames: 48, speed: slow ? 650 : 2_000)
            #expect(controller.presentation.fadeDuration == (editFadeIn ? (slow ? 0.81 : 0.23) : (slow ? 0.40 : 0.20)))
            manual.advance(by: 2)
            await settle { !controller.presentation.isVisible }
            #expect(controller.presentation.fadeDuration == (editFadeIn ? (slow ? 0.70 : 0.35) : (slow ? 0.91 : 0.46)))
        }
    }

    @Test func aLongLingerKeepsTheLastSustainingClassEvenWhenLayoutResetsSpeed() async {
        let manual = ManualClock()
        var tuning = TimelineScrollDateLabelPolicy.Tuning.standard
        tuning.linger = 10
        let (controller, _) = makeController(manual, tuning: tuning)
        flickScrollDateLabel(controller, manual)
        controller.viewportMoved(.init(isLayout: true), offsetY: 50_000)
        manual.advance(by: 9)
        await settle()
        #expect(controller.presentation.isVisible)
        manual.advance(by: 2)
        await settle { !controller.presentation.isVisible }
        #expect(
            controller.presentation.fadeDuration == 0.35, "layout did not replace the last sustaining speed with zero")
    }

    @Test func reduceMotionKeepsTheInformationAndReturnsNoFadeDuration() {
        let manual = ManualClock()
        let (controller, _) = makeController(manual)
        controller.reduceMotion = true
        flickScrollDateLabel(controller, manual, frames: 48, speed: 650)
        #expect(controller.presentation.isVisible)
        #expect(controller.presentation.fadeDuration == nil)
        controller.viewportMoved(scrollDateMovementFixture(host: true, animating: true), offsetY: 50_000)
        #expect(!controller.presentation.isVisible)
        #expect(controller.presentation.fadeDuration == nil)
    }

    @Test func aMarkedJumpAlwaysUsesTheFastFadeOut() {
        let manual = ManualClock()
        var tuning = TimelineScrollDateLabelPolicy.Tuning.standard
        tuning.fadeOut.fast = 0.27
        tuning.fadeOut.slow = 0.83
        let (controller, _) = makeController(manual, tuning: tuning)
        flickScrollDateLabel(controller, manual, frames: 48, speed: 650)
        controller.viewportMoved(scrollDateMovementFixture(host: true, animating: true), offsetY: 50_000)
        #expect(!controller.presentation.isVisible)
        #expect(controller.presentation.fadeDuration == 0.27)
    }

    @Test(arguments: [false, true])
    func aMarkedJumpEndsTheVisibleLingerAndStartsTheFastFade(system: Bool) async {
        let manual = ManualClock()
        let (controller, recorder) = makeController(manual)
        flickScrollDateLabel(controller, manual)
        await settle { manual.waiterCount == 1 }
        #expect(controller.presentation.isVisible, "SETUP: the flick shows the label")
        manual.advance(by: 0.2)
        controller.viewportMoved(
            scrollDateMovementFixture(host: !system, system: system, animating: true), offsetY: 50_000)
        #expect(!controller.policy.isVisible, "a marked jump ends the linger in the same call")
        #expect(controller.policy.hideDeadline == nil)
        #expect(!controller.presentation.isVisible)
        #expect(controller.presentation.text == "January 2026", "the text stays for the fade")
        #expect(controller.presentation.fadeDuration == 0.35, "a marked jump uses the fast fade-out")
        await settle(until: { manual.waiterCount == 0 })
        #expect(manual.waiterCount == 0, "the old linger cannot fire after the jump")
        manual.advance(by: 2)
        await settle { manual.waiterCount == 0 }
        #expect(recorder.changes.map(\.isVisible) == [true, false])
    }

    @Test func aMarkedJumpFromHiddenNeverShowsTheLabel() async {
        let manual = ManualClock()
        let (controller, recorder) = makeController(manual)
        controller.viewportMoved(scrollDateMovementFixture(host: true, animating: true), offsetY: 50_000)
        #expect(!controller.policy.isVisible)
        #expect(!controller.presentation.isVisible)
        #expect(recorder.changes.isEmpty)
        await settle(until: { manual.waiterCount == 0 })
        #expect(manual.waiterCount == 0)
    }

    @Test func userMovementAfterAJumpUsesTheNormalShowThreshold() {
        let manual = ManualClock()
        let (controller, _) = makeController(manual)
        flickScrollDateLabel(controller, manual)
        controller.viewportMoved(scrollDateMovementFixture(host: true, animating: true), offsetY: 50_000)
        var offset = 50_000.0
        for _ in 0..<12 {
            manual.advance(by: 1 / 120)
            offset += 200 / 120
            controller.viewportMoved(.init(isDragging: true), offsetY: offset)
        }
        #expect(!controller.presentation.isVisible, "slow inspection movement does not show it after the jump")
        for _ in 0..<12 {
            manual.advance(by: 1 / 120)
            offset += 2_000 / 120
            controller.viewportMoved(.init(isDragging: true), offsetY: offset)
        }
        #expect(controller.presentation.isVisible, "a later brisk drag shows it under the normal threshold")
    }

    @Test func layoutResizeAndContentMovementsKeepTheExistingLinger() {
        for movement in [
            TimelineScrollDateLabelMovement(isLayout: true),
            .init(isHostDriven: true, isLayout: true),
            .init(isHostDriven: true),
            .init(isLayout: true, isJump: true),
        ] {
            let manual = ManualClock()
            let (controller, _) = makeController(manual)
            flickScrollDateLabel(controller, manual)
            let deadline = controller.policy.hideDeadline
            controller.viewportMoved(movement, offsetY: 50_000)
            manual.advance(by: 1 / 120)
            controller.userMoved(offsetY: 50_000)
            #expect(controller.presentation.isVisible)
            #expect(controller.policy.hideDeadline == deadline)
        }
    }

    @Test func briskScrollShowsTextAndHidesAfterLinger() async {
        let manual = ManualClock()
        let (controller, recorder) = makeController(manual)
        flickScrollDateLabel(controller, manual)
        #expect(
            controller.presentation
                == .init(isVisible: true, text: "January 2026", fadeDuration: TimelineScrollDateLabelMotion.fadeIn.fast)
        )
        await settle(until: { manual.waiterCount == 1 })
        #expect(manual.waiterCount == 1)
        manual.advance(by: 1.1)
        await settle(until: { !controller.presentation.isVisible })
        #expect(!controller.presentation.isVisible)
        #expect(controller.presentation.text == "January 2026", "the text stays while the label fades out")
        await settle(until: { manual.waiterCount == 0 })
        #expect(manual.waiterCount == 0)
        #expect(recorder.changes.map(\.isVisible) == [true, false])
    }

    @Test func anchorUpdatesTheTextOnlyWhenTheMonthChanges() {
        let manual = ManualClock()
        let (controller, recorder) = makeController(manual)
        flickScrollDateLabel(controller, manual)
        for anchor in [1, 5, 9] { controller.setAnchor(flatIndex: anchor) }
        #expect(recorder.changes.count == 1, "moving inside January publishes nothing")
        controller.setAnchor(flatIndex: 10)
        controller.setAnchor(flatIndex: 15)
        #expect(recorder.changes.map(\.text) == ["January 2026", "February 2026"])
    }

    @Test func movementWithinLingerMovesTheDeadlineWithoutANewTask() async {
        let manual = ManualClock()
        let (controller, _) = makeController(manual)
        flickScrollDateLabel(controller, manual)
        await settle(until: { manual.waiterCount == 1 })
        manual.advance(by: 0.8)
        flickScrollDateLabel(controller, manual, frames: 4)
        await settle()
        #expect(controller.presentation.isVisible)
        await settle(until: { manual.waiterCount == 1 })
        #expect(manual.waiterCount == 1, "one waiting hide at a time")
        manual.advance(by: 0.5)
        await settle()
        #expect(controller.presentation.isVisible, "the deadline moved with the new movement")
        manual.advance(by: 0.6)
        await settle(until: { !controller.presentation.isVisible })
        #expect(!controller.presentation.isVisible)
    }

    @Test func pinchAndRouteChangeHideAtOnceAndCancelThePendingFade() async {
        let manual = ManualClock()
        let (controller, recorder) = makeController(manual)
        flickScrollDateLabel(controller, manual)
        await settle(until: { manual.waiterCount == 1 })
        controller.suppress()
        #expect(!controller.presentation.isVisible)
        await settle(until: { manual.waiterCount == 0 })
        #expect(manual.waiterCount == 0, "the cancelled sleeper is gone")
        controller.resume()
        flickScrollDateLabel(controller, manual)
        #expect(controller.presentation.isVisible)
        #expect(recorder.changes.map(\.isVisible) == [true, false, true])
    }

    @Test func retiredHostReceivesNoDelayedCallback() async {
        let manual = ManualClock()
        let (controller, recorder) = makeController(manual)
        flickScrollDateLabel(controller, manual)
        await settle(until: { manual.waiterCount == 1 })
        // The host's callback keeps the host alive; retiring must release it.
        final class HostStandIn {}
        var host: HostStandIn? = HostStandIn()
        weak let weakHost = host
        controller.onChange = { [host] presentation in
            _ = host
            recorder.changes.append(presentation)
        }
        host = nil
        controller.retire()
        #expect(weakHost == nil, "retire drops the host callback")
        await settle(until: { manual.waiterCount == 0 })
        #expect(manual.waiterCount == 0, "retire cancels the pending hide")
        #expect(controller.isRetired)
        manual.advance(by: 5)
        await settle()
        flickScrollDateLabel(controller, manual)
        #expect(recorder.changes.map(\.isVisible) == [true])
    }

    @Test func aReplacedListHidesStaleDatesUntilItsMarkersArrive() async {
        let manual = ManualClock()
        let gated = GatedBuilder()
        let controller = TimelineScrollDateLabelController(clock: manual.clock, build: gated.build)
        controller.updateContent(items(), replacesList: true)
        await settle(until: { gated.waiting == 1 })
        gated.releaseAll()
        await settle(until: { controller.index != nil })
        controller.setAnchor(flatIndex: 0)
        flickScrollDateLabel(controller, manual)
        #expect(controller.presentation.isVisible)
        // Another account or filter: the label leaves at once and stays away while the new markers build.
        controller.updateContent(Array(items().reversed()), replacesList: true)
        #expect(controller.presentation == .hidden)
        await settle(until: { gated.waiting == 1 })
        flickScrollDateLabel(controller, manual)
        #expect(!controller.presentation.isVisible, "no markers, no label")
        gated.releaseAll()
        await settle(until: { controller.index != nil })
        flickScrollDateLabel(controller, manual)
        #expect(controller.presentation.isVisible, "the new list's markers show again")
    }

    @Test func aRefreshKeepsTheLabelWhileItsMarkersRebuild() async {
        let manual = ManualClock()
        let gated = GatedBuilder()
        let controller = TimelineScrollDateLabelController(clock: manual.clock, build: gated.build)
        controller.updateContent(items(), replacesList: true)
        await settle(until: { gated.waiting == 1 })
        gated.releaseAll()
        await settle(until: { controller.index != nil })
        controller.setAnchor(flatIndex: 0)
        flickScrollDateLabel(controller, manual)
        #expect(
            controller.presentation
                == .init(isVisible: true, text: "January 2026", fadeDuration: TimelineScrollDateLabelMotion.fadeIn.fast)
        )
        // A library update adds a photo: the label stays while the new markers build.
        controller.updateContent(items() + items().prefix(1), replacesList: false)
        await settle(until: { gated.waiting == 1 })
        #expect(
            controller.presentation
                == .init(isVisible: true, text: "January 2026", fadeDuration: TimelineScrollDateLabelMotion.fadeIn.fast)
        )
        gated.releaseAll()
        await settle(until: { controller.index?.itemCount == 41 })
        #expect(controller.presentation.isVisible)
    }

    @Test func aReplacedListNeverInstallsTheOldListsRunningBuild() async {
        let gated = GatedBuilder()
        let controller = TimelineScrollDateLabelController(clock: ManualClock().clock, build: gated.build)
        var installed: [Int] = []
        controller.onIndexInstalled = { installed.append($0.itemCount) }
        let old = items()
        controller.updateContent(old, replacesList: true)
        await settle(until: { gated.waiting == 1 })
        // Another account replaces the list while the old build still runs.
        let new = Array(old.prefix(25))
        controller.updateContent(new, replacesList: true)
        gated.releaseAll()
        await settle(until: { gated.waiting == 1 })
        #expect(installed.isEmpty, "the old list's markers never arrive")
        #expect(controller.index == nil)
        gated.releaseAll()
        await settle(until: { installed == [25] })
        #expect(installed == [25])
        #expect(gated.maximumRunning == 1)
    }

    @Test func suppressionsAndRouteHidesTakeEffectAtOnceWhileTheLingerHideFades() async {
        let manual = ManualClock()
        let (controller, _) = makeController(manual)
        flickScrollDateLabel(controller, manual)
        #expect(controller.presentation.isVisible && controller.presentation.fadeDuration != nil, "a show fades in")
        controller.hide()
        #expect(controller.presentation.fadeDuration == nil, "opening a photo hides at once")
        flickScrollDateLabel(controller, manual)
        controller.suppress()
        #expect(
            !controller.presentation.isVisible && controller.presentation.fadeDuration == nil,
            "a suppression hides at once")
        controller.resume()
        flickScrollDateLabel(controller, manual)
        await settle(until: { manual.waiterCount == 1 })
        manual.advance(by: 1.1)
        await settle(until: { !controller.presentation.isVisible })
        #expect(controller.presentation.fadeDuration != nil, "the hide after the linger time fades")
        flickScrollDateLabel(controller, manual)
        controller.setIndex(nil)
        #expect(
            !controller.presentation.isVisible && controller.presentation.fadeDuration == nil,
            "stale content hides at once")
    }

    @Test func aSuppressionDuringTheFadeOutStillReachesTheHostAtOnce() async {
        let manual = ManualClock()
        let (controller, recorder) = makeController(manual)
        var immediate: [Bool] = []
        controller.onChange = { presentation in
            recorder.changes.append(presentation)
            immediate.append(controller.presentation.fadeDuration == nil)
        }
        flickScrollDateLabel(controller, manual)
        await settle(until: { manual.waiterCount == 1 })
        manual.advance(by: 1.1)
        await settle(until: { !controller.presentation.isVisible })
        #expect(immediate == [false, false], "the show and the linger hide fade")
        // The label fades out now; the app switcher or a viewer must not wait for the fade.
        controller.suppress()
        #expect(immediate == [false, false, true], "the host hears the immediate hide although nothing else changed")
        controller.resume()
        controller.hide()
        #expect(immediate == [false, false, true, true])
    }

    @Test func openingAPhotoHidesTheLabelAtOnceAndCancelsItsFade() async {
        let manual = ManualClock()
        let (controller, recorder) = makeController(manual)
        flickScrollDateLabel(controller, manual)
        await settle(until: { manual.waiterCount == 1 })
        controller.hide()
        #expect(controller.presentation.isVisible == false)
        await settle(until: { manual.waiterCount == 0 })
        #expect(manual.waiterCount == 0)
        #expect(recorder.changes.map(\.isVisible) == [true, false])
    }

    @Test func classifiedMovementsDriveTheLabel() {
        let manual = ManualClock()
        let (controller, _) = makeController(manual)
        var offset = 0.0
        // Host-driven and layout movements never show the label, however fast.
        for movement in [TimelineScrollDateLabelMovement(isHostDriven: true), .init(isLayout: true)] {
            for _ in 0..<12 {
                controller.viewportMoved(movement, offsetY: offset)
                manual.advance(by: 1 / 120)
                offset += 5_000 / 120
            }
            #expect(!controller.presentation.isVisible)
        }
        // A continuous movement without flags (a native indicator drag) shows it.
        for _ in 0..<12 {
            controller.viewportMoved(.init(), offsetY: offset)
            manual.advance(by: 1 / 120)
            offset += 2_000 / 120
        }
        #expect(controller.presentation.isVisible)
    }

    @Test func resizeAndProgrammaticPlacementDoNotShowTheLabel() {
        let manual = ManualClock()
        let (controller, _) = makeController(manual)
        controller.userMoved(offsetY: 0)
        manual.advance(by: 1 / 120)
        controller.nonUserMoved()
        controller.userMoved(offsetY: 30_000)
        manual.advance(by: 1 / 120)
        controller.userMoved(offsetY: 30_001)
        #expect(!controller.presentation.isVisible)
    }
}

@Suite struct TimelineScrollDateLabelGeometryTests {
    @Test func actualThumbLengthDeterminesTheCenterAtFiveFractions() {
        for (top, expected) in zip([CGFloat(100), 250, 400, 550, 700], [CGFloat(150), 300, 450, 600, 750]) {
            #expect(
                TimelineScrollDateLabelGeometry.centerY(
                    thumbTop: top, thumbLength: 100, viewportTop: 0, viewportBottom: 900, labelHeight: 30) == expected)
        }
        #expect(
            TimelineScrollDateLabelGeometry.centerY(
                thumbTop: 100, thumbLength: 7, viewportTop: 0, viewportBottom: 900, labelHeight: 30) == 103.5,
            "a squeezed native thumb keeps its actual center")
    }

    @Test func followsTheScrollIndicatorFromTopToBottom() {
        func center(_ offset: CGFloat) -> CGFloat? {
            TimelineScrollDateLabelGeometry.centerY(
                thumbTop: 100 + min(max((offset + 100) / 10_000, 0), 1) * 670, thumbLength: 30, viewportTop: 100,
                viewportBottom: 800, labelHeight: 30)
        }
        #expect(center(-100) == 115)
        #expect(center(9_900) == 785)
        #expect(center(4_900) == 450)
        #expect(center(-400) == 115, "rubber band at the top stays on the track")
        #expect(center(20_000) == 785)
    }

    @Test func skipsAFoldBandWithoutCoveringIt() throws {
        let band: ClosedRange<CGFloat> = 430...470
        var previous: CGFloat = 0
        for step in 0...100 {
            let y = try #require(
                TimelineScrollDateLabelGeometry.centerY(
                    thumbTop: 100 + CGFloat(step) / 100 * 670, thumbLength: 30, viewportTop: 100, viewportBottom: 800,
                    labelHeight: 30, avoiding: [band]))
            #expect(y - 15 >= 100 && y + 15 <= 800)
            #expect(y + 15 <= band.lowerBound || y - 15 >= band.upperBound, "label at \(y) covers the fold")
            #expect(y >= previous, "the label moves in one direction")
            previous = y
        }
    }

    @Test func onlyRegionsInTheTrailingColumnMoveTheLabel() {
        let verticalFold = CGRect(x: 455, y: 0, width: 40, height: 669)  // Open device: crease in the middle.
        let tabletopFold = CGRect(x: 0, y: 310, width: 951, height: 50)
        let leadingCamera = CGRect(x: 20, y: 0, width: 60, height: 30)
        let bands = TimelineScrollDateLabelGeometry.bands(
            avoiding: [tabletopFold, verticalFold, leadingCamera], trailingColumnFrom: 700)
        #expect(bands == [310...360])
        // The crease of an open 867 pt wide grid lies outside the label column, whatever the column width.
        let columnMinX = TimelineScrollDateLabelMotion.columnMinX(width: 867, trailingInset: 0)
        #expect(columnMinX > verticalFold.maxX)
        #expect(TimelineScrollDateLabelGeometry.bands(avoiding: [verticalFold], trailingColumnFrom: columnMinX).isEmpty)
    }

    @Test func theEndOfTheTrackStaysPlacedDespiteRounding() throws {
        // A native thumb at the bottom stays placed despite fractional viewport and label dimensions.
        let y = try #require(
            TimelineScrollDateLabelGeometry.centerY(
                thumbTop: 745.75 - 44.07, thumbLength: 44.07, viewportTop: 114.94, viewportBottom: 745.75,
                labelHeight: 44.07,
                avoiding: [435.21...446.74]))
        #expect(abs(y - (745.75 - 44.07 / 2)) < 0.001)
    }

    /// Deterministic random layouts: whenever some free segment can hold the label, every scroll fraction places it
    /// inside the track and outside every band.
    @Test func everyFractionPlacesTheLabelWhenAnySegmentHoldsIt() {
        var random = SplitMix64(seed: 0x777)
        var checked = 0
        for _ in 0..<20_000 {
            let top = random.next(in: 0...200)
            let bottom = top + random.next(in: 40...900)
            let height = random.next(in: 20...60)
            var bands: [ClosedRange<CGFloat>] = []
            for _ in 0..<Int(random.next(in: 0...2.99)) {
                let lower = random.next(in: top...bottom)
                bands.append(lower...(lower + random.next(in: 1...80)))
            }
            bands.sort { $0.lowerBound < $1.lowerBound }
            let fits = Self.freeSegments(top: top, bottom: bottom, bands: bands).contains {
                $0.upperBound - $0.lowerBound >= height
            }
            for fraction in [0, 0.25, 0.5, 0.999_999, 1, random.next(in: 0...1)] as [CGFloat] {
                let y = TimelineScrollDateLabelGeometry.centerY(
                    thumbTop: top + fraction * (bottom - top - height), thumbLength: height, viewportTop: top,
                    viewportBottom: bottom,
                    labelHeight: height, avoiding: bands)
                guard fits else {
                    #expect(y == nil)
                    continue
                }
                guard let y else {
                    Issue.record(
                        "no place for fraction \(fraction), track \(top)...\(bottom), height \(height), bands \(bands)")
                    return
                }
                let tolerance: CGFloat = 0.000_1
                #expect(y - height / 2 >= top - tolerance && y + height / 2 <= bottom + tolerance)
                for band in bands {
                    let clear =
                        y + height / 2 <= band.lowerBound + tolerance || y - height / 2 >= band.upperBound - tolerance
                    #expect(clear, "label at \(y) covers \(band)")
                }
                checked += 1
            }
        }
        #expect(checked > 50_000)
    }

    /// Reference free segments for the property test, computed independently from the production visitor.
    private static func freeSegments(
        top: CGFloat, bottom: CGFloat, bands: [ClosedRange<CGFloat>]
    ) -> [ClosedRange<CGFloat>] {
        var segments: [ClosedRange<CGFloat>] = []
        var cursor = top
        for band in bands where band.upperBound > cursor && band.lowerBound < bottom {
            if band.lowerBound > cursor { segments.append(cursor...band.lowerBound) }
            cursor = max(cursor, band.upperBound)
        }
        if cursor < bottom { segments.append(cursor...bottom) }
        return segments
    }

    @Test func returnsNilWhenNoSegmentHoldsTheLabel() {
        #expect(
            TimelineScrollDateLabelGeometry.centerY(
                thumbTop: 0, thumbLength: 30, viewportTop: 0, viewportBottom: 50, labelHeight: 30,
                avoiding: [10...40]) == nil)
    }
}

@Suite struct TimelineScrollDateLabelEligibilityTests {
    private func projection(
        query: String, names: [PhotoUID: String], semantic: Set<PhotoUID>? = nil
    ) -> TimelineSearchProjection {
        let calendar = Calendar(identifier: .gregorian)
        let items = (0..<3).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "n\($0)"),
                captureTime: calendar.date(from: DateComponents(year: 2026, month: 1 + $0, day: 1))!,
                mediaType: "image/jpeg")
        }
        let section = TimelineSection(id: "s", date: items[0].captureTime, title: "s", items: items)
        return TimelineSearchProjection(
            key: TimelineSearchProjectionKey(
                sourceRevision: 1, query: query,
                context: TimelineSearchContext(photoNames: PhotoNameIndex(names: names, revision: 1)),
                semanticMatches: semantic, refinement: .all),
            sections: [section])
    }

    @Test func libraryAndDateOrderedResultsShowTheLabel() {
        #expect(
            TimelineScrollDateLabelEligibility.showsLabel(
                isLoading: false, hasFailure: false, hasProjectionCriteria: false, resolvedProjection: nil))
        let dateOrdered = projection(query: "beach", names: [:])
        #expect(dateOrdered.isDateOrdered)
        #expect(
            TimelineScrollDateLabelEligibility.showsLabel(
                isLoading: false, hasFailure: false, hasProjectionCriteria: true, resolvedProjection: dateOrdered))
    }

    @Test func aFailedLoadShowsNoLabelEvenWithCachedPhotos() {
        #expect(
            !TimelineScrollDateLabelEligibility.showsLabel(
                isLoading: false, hasFailure: true, hasProjectionCriteria: false, resolvedProjection: nil))
        #expect(
            !TimelineScrollDateLabelEligibility.showsLabel(
                isLoading: false, hasFailure: true, hasProjectionCriteria: true,
                resolvedProjection: projection(query: "beach", names: [:])))
    }

    @Test func loadingPendingAndNameLedResultsShowNoLabel() {
        #expect(
            !TimelineScrollDateLabelEligibility.showsLabel(
                isLoading: true, hasFailure: false, hasProjectionCriteria: false, resolvedProjection: nil))
        #expect(
            !TimelineScrollDateLabelEligibility.showsLabel(
                isLoading: false, hasFailure: false, hasProjectionCriteria: true, resolvedProjection: nil),
            "a pending projection")
        let nameLed = projection(
            query: "IMG_0001", names: [PhotoUID(volumeID: "v", nodeID: "n0"): "IMG_0001.HEIC"],
            semantic: [PhotoUID(volumeID: "v", nodeID: "n1"), PhotoUID(volumeID: "v", nodeID: "n2")])
        #expect(nameLed.presentationItems.count == 3)
        #expect(!nameLed.isDateOrdered)
        #expect(
            !TimelineScrollDateLabelEligibility.showsLabel(
                isLoading: false, hasFailure: false, hasProjectionCriteria: true, resolvedProjection: nameLed))
    }
}

/// A builder whose builds finish only when the test releases them.
@MainActor
private final class GatedBuilder {
    private(set) var requested: [Int] = []
    private(set) var running = 0
    private(set) var maximumRunning = 0
    private var gates: [CheckedContinuation<Void, Never>] = []
    /// Set by a cancellation that reached a build.
    let cancellations = TimelineTestCounter()

    var build: TimelineScrollDateIndexScheduler.Builder {
        { [self] items, revision in
            let counter = cancellations
            await withTaskCancellationHandler {
                await self.wait(count: items.count)
            } onCancel: {
                counter.increment()
            }
            await self.finish()
            return TimelineScrollDateIndex.build(
                items: items, revision: revision, calendar: Calendar(identifier: .gregorian),
                locale: Locale(identifier: "en_US"))
        }
    }

    private func wait(count: Int) async {
        requested.append(count)
        running += 1
        maximumRunning = max(maximumRunning, running)
        await withCheckedContinuation { gates.append($0) }
    }

    private func finish() { running -= 1 }

    var waiting: Int { gates.count }

    func releaseAll() {
        let released = gates
        gates.removeAll()
        released.forEach { $0.resume() }
    }
}

@MainActor
@Suite struct TimelineScrollDateIndexSchedulerTests {
    @Test func refreshesDuringABuildCoalesceToTheNewestList() async {
        let gated = GatedBuilder()
        let scheduler = TimelineScrollDateIndexScheduler(build: gated.build)
        var received: [Int?] = []
        scheduler.onIndex = { received.append($0?.itemCount) }
        scheduler.update(items: scrollDateIndexItems(10))
        await settle(until: { gated.waiting == 1 })
        // Five refreshes arrive while the first build runs.
        for count in 11...15 { scheduler.update(items: scrollDateIndexItems(count)) }
        gated.releaseAll()
        await settle(until: { gated.waiting == 1 })
        gated.releaseAll()
        await settle(until: { received == [10, 15] })
        #expect(gated.requested == [10, 15], "the stale lists 11 to 14 are skipped")
        #expect(received == [10, 15], "every finished build reports, the newest last")
    }

    @Test func anEmptyListReportsNilAndDropsTheRunningBuild() async {
        let gated = GatedBuilder()
        let scheduler = TimelineScrollDateIndexScheduler(build: gated.build)
        var received: [Int?] = []
        scheduler.onIndex = { received.append($0?.itemCount) }
        scheduler.update(items: scrollDateIndexItems(10))
        await settle(until: { gated.waiting == 1 })
        scheduler.update(items: [])
        gated.releaseAll()
        await settle()
        #expect(received == [nil], "the old list's index never arrives after the empty list")
        #expect(gated.running == 0)
    }

    @Test func cancelStopsEveryLaterResult() async {
        let gated = GatedBuilder()
        let scheduler = TimelineScrollDateIndexScheduler(build: gated.build)
        var received: [Int?] = []
        scheduler.onIndex = { received.append($0?.itemCount) }
        scheduler.update(items: scrollDateIndexItems(10))
        await settle(until: { gated.waiting == 1 })
        scheduler.cancel()
        gated.releaseAll()
        await settle()
        #expect(received.isEmpty)
        // A later update starts a new build.
        scheduler.update(items: scrollDateIndexItems(3))
        await settle(until: { gated.waiting == 1 })
        gated.releaseAll()
        await settle(until: { received == [3] })
        #expect(received == [3])
    }
}

@MainActor
@Suite struct TimelineScrollDateLabelReplacementTests {
    @Test func aLookupOutsideTheMarkersKeepsTheLastMonth() {
        let calendar = timelineTestUTCCalendar
        let manual = ManualClock()
        let controller = TimelineScrollDateLabelController(clock: manual.clock)
        let photos = (0..<20).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "n\($0)"),
                captureTime: calendar.date(from: DateComponents(year: 2026, month: 3, day: 1 + $0))!,
                mediaType: "image/jpeg")
        }
        controller.setIndex(
            TimelineScrollDateIndex.build(
                items: photos, revision: 1, calendar: calendar, locale: Locale(identifier: "en_US")))
        controller.setAnchor(flatIndex: 5)
        var offset = 0.0
        for _ in 0..<12 {
            controller.userMoved(offsetY: offset)
            manual.advance(by: 1 / 120)
            offset += 2_000 / 120
        }
        #expect(
            controller.presentation
                == .init(isVisible: true, text: "March 2026", fadeDuration: TimelineScrollDateLabelMotion.fadeIn.fast))
        // A refresh grew the list; its markers are still building, so index 30 lies outside the current ones.
        controller.setAnchor(flatIndex: 30)
        #expect(
            controller.presentation
                == .init(isVisible: true, text: "March 2026", fadeDuration: TimelineScrollDateLabelMotion.fadeIn.fast),
            "no flicker during a refresh")
    }
}

/// A small deterministic generator, so the property tests repeat exactly.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        let unit = CGFloat(nextUInt64() >> 11) / CGFloat(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

@MainActor
@Suite struct TimelineScrollDateIndexSchedulerCancellationTests {
    @Test func cancellingReachesTheBuildAndTheNextBuildWaitsForIt() async {
        let gated = GatedBuilder()
        let scheduler = TimelineScrollDateIndexScheduler(build: gated.build)
        var received: [Int?] = []
        scheduler.onIndex = { received.append($0?.itemCount) }
        scheduler.update(items: scrollDateIndexItems(10))
        await settle(until: { gated.waiting == 1 })
        scheduler.cancel()
        #expect(gated.cancellations.value == 1, "the cancellation reaches the running build")
        // A new list arrives while the cancelled build has not ended yet.
        scheduler.update(items: scrollDateIndexItems(4))
        await settle()
        #expect(gated.requested == [10], "the next build waits for the cancelled one")
        gated.releaseAll()
        await settle(until: { gated.waiting == 1 })
        #expect(gated.requested == [10, 4])
        #expect(gated.maximumRunning == 1, "never two builds at once")
        gated.releaseAll()
        await settle(until: { received == [4] })
        #expect(received == [4], "the cancelled build reports nothing")
    }

    @Test func theDefaultBuilderStopsWhenCancelled() async {
        let many = scrollDateIndexItems(200_000)
        let task = Task { await TimelineScrollDateIndexScheduler.detachedBuild(many, 1) }
        task.cancel()
        let index = await task.value
        #expect(index == nil, "a cancelled build returns no index")
    }
}

@Suite struct TimelineScrollDateLabelInputTests {
    @Test func hostDrivenAndLayoutMovementsNeverCount() {
        let counts = scrollDateMovementClassifier()
        #expect(!counts(.init(isHostDriven: true, isDragging: true), 0))
        #expect(!counts(.init(isLayout: true, isDecelerating: true), 0.01))
        #expect(!counts(.init(isTracking: true, isJump: true), 0.02))
    }

    @Test func touchDecelerationAndSystemAnimationsCount() {
        let counts = scrollDateMovementClassifier()
        #expect(counts(.init(isTracking: true), 0))
        #expect(counts(.init(isDragging: true), 0.01))
        #expect(counts(.init(isDecelerating: true), 0.02))
        #expect(counts(.init(isSystemAnimation: true), 0.03), "a keyboard page key")
    }

    @Test func onlyAContinuousUnflaggedMovementCounts() {
        let counts = scrollDateMovementClassifier()
        #expect(!counts(.init(), 0), "one jump alone is layout-like")
        #expect(counts(.init(), 0.008), "the next frame continues the movement")
        #expect(counts(.init(), 0.016))
        #expect(!counts(.init(), 0.5), "a later single change starts over")
        #expect(!counts(.init(isLayout: true), 0.508))
        #expect(!counts(.init(), 0.516), "a layout pass breaks the continuation")
    }

    @Test func jumpsCountOnlyWhileTheirAnimationRuns() {
        #expect(
            scrollDateMovementFixture(host: true, animating: true).isHostDriven, "the tab retap animation is a jump")
        #expect(
            scrollDateMovementFixture(system: true, animating: true).isHostDriven,
            "the status-bar scroll to top is a jump")
        #expect(!scrollDateMovementFixture(system: true, animating: true).isSystemAnimation)
        // A touch ended the jump animation without a callback: the stale flag must not swallow the person's flick.
        let interrupted = scrollDateMovementFixture(host: true, system: true, dragging: true, animating: false)
        #expect(!interrupted.isHostDriven)
        #expect(interrupted.isDragging)
        #expect(
            scrollDateMovementFixture(animating: true).isSystemAnimation, "a keyboard page key is the person's input")
        #expect(scrollDateMovementFixture(programmatic: true, animating: false).isHostDriven)
        #expect(
            !scrollDateMovementFixture(programmatic: true, animating: false).isJump,
            "generic host adjustments only reset speed")
        #expect(scrollDateMovementFixture(host: true, animating: true).isJump)
        #expect(scrollDateMovementFixture(system: true, animating: true).isJump)
        #expect(!interrupted.isJump)
        #expect(
            scrollDateMovementFixture(programmatic: true, animating: false, applyingJump: true).isJump,
            "a synchronous navigation jump")
        #expect(
            !scrollDateMovementFixture(host: true, animating: true, layout: true).isJump,
            "layout is not a navigation jump")
        #expect(
            !scrollDateMovementFixture(programmatic: true, animating: false, applyingJump: true, layout: true).isJump)
    }

    @Test func everySuppressingHostStateHidesTheLabel() {
        let showing = TimelineScrollDateLabelHostState(
            hasWindow: true, isActive: true, isBackgrounded: false, isTransforming: false, hasItems: true,
            isScrollable: true)
        #expect(!showing.suppressesLabel)
        var states: [TimelineScrollDateLabelHostState] = []
        for change in 0..<6 {
            var state = showing
            switch change {
            case 0: state.hasWindow = false
            case 1: state.isActive = false
            case 2: state.isBackgrounded = true
            case 3: state.isTransforming = true
            case 4: state.hasItems = false
            default: state.isScrollable = false
            }
            states.append(state)
        }
        #expect(states.allSatisfy { $0.suppressesLabel })
    }
}

@Suite struct TimelineScrollDateLabelTextSizeCacheTests {
    @Test func nativeMeasurementRunsOnceUntilInvalidation() {
        var cache = TimelineScrollDateLabelTextSizeCache(horizontalPadding: 12, verticalPadding: 6)
        var measurements = 0
        let first = cache.fittingSize {
            measurements += 1
            return CGSize(width: 106.2, height: 17.3)
        }
        let repeated = cache.fittingSize {
            measurements += 1
            return CGSize(width: 200, height: 25)
        }
        #expect(first == CGSize(width: 131, height: 30))
        #expect(repeated == first)
        #expect(measurements == 1)
        cache.invalidate()
        let resized = cache.fittingSize {
            measurements += 1
            return CGSize(width: 200, height: 25)
        }
        #expect(resized == CGSize(width: 224, height: 37))
        #expect(measurements == 2)
    }

    @Test func platformPaddingKeepsNativeContentFitting() {
        var cache = TimelineScrollDateLabelTextSizeCache(horizontalPadding: 10, verticalPadding: 6)
        let size = cache.fittingSize { CGSize(width: 110.201, height: 18) }
        #expect(size == CGSize(width: 131, height: 30))
        #expect(
            cache.contentFrame(in: CGRect(origin: .zero, size: size)) == CGRect(x: 10, y: 6, width: 111, height: 18))
    }
}

@MainActor
@Suite struct TimelineScrollDateLabelSessionTests {
    @Test func enablingUsesTheLatestContentAndDisablingDropsItsIndex() async throws {
        let gated = GatedBuilder()
        let controller = TimelineScrollDateLabelController(clock: ManualClock().clock, build: gated.build)
        let session = TimelineScrollDateLabelSession(controller: controller)
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "item"), captureTime: Date(timeIntervalSince1970: 1_780_000_000),
            mediaType: "image/jpeg")
        session.contentChanged([item], replacesList: true)
        await settle()
        #expect(gated.requested.isEmpty, "disabled content does not build an index")
        session.setEnabled(true)
        await settle(until: { gated.waiting == 1 })
        try #require(gated.requested == [1], "enabling builds the retained content")
        gated.releaseAll()
        await settle(until: { controller.index != nil })
        #expect(controller.index?.itemCount == 1)
        session.setEnabled(false)
        #expect(controller.index == nil)
        session.contentChanged([item, item], replacesList: false)
        session.setEnabled(true)
        await settle(until: { gated.waiting == 1 })
        #expect(gated.requested == [1, 2], "re-enabling builds the newest content")
        gated.releaseAll()
        await settle(until: { controller.index?.itemCount == 2 })
        #expect(controller.index?.itemCount == 2)
    }
}
