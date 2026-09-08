#if canImport(UIKit)
    import QuartzCore
    import UIKit

    public struct UIKitTimelineDisplayFrame: Sendable {
        public let timestamp: CFTimeInterval
        public let targetTimestamp: CFTimeInterval
        public let duration: CFTimeInterval

        public init(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval, duration: CFTimeInterval) {
            self.timestamp = timestamp
            self.targetTimestamp = targetTimestamp
            self.duration = duration
        }
    }

    public enum UIKitTimelineFrameRatePolicy {
        /// Apple's high-impact-animation hint on a 120-Hz surface. Slower surfaces keep Core Animation's
        /// system-controlled default so power, thermal, and accessibility policy can choose the current cadence.
        public static func preferredRange(maximumFramesPerSecond: Int) -> CAFrameRateRange {
            guard maximumFramesPerSecond >= 120 else { return .default }
            return CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        }
    }

    @MainActor
    protocol UIKitTimelineDisplayLinkScheduling: AnyObject, Sendable {
        var isPaused: Bool { get set }
        var preferredFrameRateRange: CAFrameRateRange { get set }
        func invalidate()
    }

    @MainActor
    private final class SystemTimelineDisplayLink: UIKitTimelineDisplayLinkScheduling {
        private final class CallbackTarget: NSObject {
            let onFrame: (UIKitTimelineDisplayFrame) -> Void

            init(onFrame: @escaping (UIKitTimelineDisplayFrame) -> Void) {
                self.onFrame = onFrame
            }

            @MainActor
            @objc func tick(_ displayLink: CADisplayLink) {
                onFrame(
                    UIKitTimelineDisplayFrame(
                        timestamp: displayLink.timestamp,
                        targetTimestamp: displayLink.targetTimestamp,
                        duration: displayLink.duration
                    ))
            }
        }

        private let callbackTarget: CallbackTarget
        private let displayLink: CADisplayLink

        init(onFrame: @escaping (UIKitTimelineDisplayFrame) -> Void) {
            let callbackTarget = CallbackTarget(onFrame: onFrame)
            self.callbackTarget = callbackTarget
            displayLink = CADisplayLink(target: callbackTarget, selector: #selector(CallbackTarget.tick(_:)))
            displayLink.isPaused = true
            displayLink.add(to: .main, forMode: .common)
        }

        var isPaused: Bool {
            get { displayLink.isPaused }
            set { displayLink.isPaused = newValue }
        }

        var preferredFrameRateRange: CAFrameRateRange {
            get { displayLink.preferredFrameRateRange }
            set { displayLink.preferredFrameRateRange = newValue }
        }

        func invalidate() {
            displayLink.invalidate()
        }
    }

    /// One persistent display-link installation for one UIKit render surface.
    ///
    /// `pause()` is the ordinary idle/offscreen operation. `stop()` is reserved for final teardown, because
    /// invalidating and recreating the link at every warm frame adds main-run-loop churn exactly when scrolling.
    @MainActor
    public final class UIKitTimelineDisplayLinkDriver {
        typealias Factory = (@escaping (UIKitTimelineDisplayFrame) -> Void) -> any UIKitTimelineDisplayLinkScheduling

        private let makeDisplayLink: Factory
        private var displayLink: (any UIKitTimelineDisplayLinkScheduling)?
        private var onFrame: ((UIKitTimelineDisplayFrame) -> Void)?
        private var configuredMaximumFramesPerSecond: Int?

        public private(set) var isRunning = false
        public private(set) var installationCount = 0

        public convenience init() {
            self.init(makeDisplayLink: { SystemTimelineDisplayLink(onFrame: $0) })
        }

        init(makeDisplayLink: @escaping Factory) {
            self.makeDisplayLink = makeDisplayLink
        }

        deinit {
            // Run loops retain installed links even after their driver disappears. Transfer only the link,
            // never self, to the main actor if the owner omitted explicit final teardown.
            if let displayLink {
                Task { @MainActor in displayLink.invalidate() }
            }
        }

        public func configure(maximumFramesPerSecond: Int) {
            let maximum = max(1, maximumFramesPerSecond)
            guard configuredMaximumFramesPerSecond != maximum else { return }
            configuredMaximumFramesPerSecond = maximum
            displayLink?.preferredFrameRateRange = UIKitTimelineFrameRatePolicy.preferredRange(
                maximumFramesPerSecond: maximum)
        }

        public func start(
            maximumFramesPerSecond: Int,
            onFrame: @escaping (UIKitTimelineDisplayFrame) -> Void
        ) {
            self.onFrame = onFrame
            if displayLink == nil {
                let link = makeDisplayLink { [weak self] frame in
                    self?.onFrame?(frame)
                }
                displayLink = link
                installationCount += 1
                if let configuredMaximumFramesPerSecond {
                    link.preferredFrameRateRange = UIKitTimelineFrameRatePolicy.preferredRange(
                        maximumFramesPerSecond: configuredMaximumFramesPerSecond)
                }
            }
            configure(maximumFramesPerSecond: maximumFramesPerSecond)
            displayLink?.isPaused = false
            isRunning = true
        }

        public func pause() {
            displayLink?.isPaused = true
            isRunning = false
        }

        /// Final teardown only. Ordinary idle, tab, window, and app lifecycle transitions call `pause()`.
        public func stop() {
            displayLink?.invalidate()
            displayLink = nil
            onFrame = nil
            configuredMaximumFramesPerSecond = nil
            isRunning = false
        }
    }
#endif
