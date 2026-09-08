#if canImport(UIKit)
    import Foundation
    import MetalGridTextureCore
    import os
    import QuartzCore
    import TimelineUIKitAdapter

    enum UIKitGridScrollPhase: String, Sendable {
        case idle
        case tracking
        case dragging
        case decelerating
        case animating
    }

    struct DisplayCadenceSnapshot: Equatable, Sendable {
        var intervalSamples = 0
        var intervalMisses = 0
        var deadlineMisses = 0
        var intervalTotal: CFTimeInterval = 0
        var targetIntervalTotal: CFTimeInterval = 0
        var maxInterval: CFTimeInterval = 0
    }

    /// Pure cadence accounting used by diagnostics and deterministic 60/120-Hz tests.
    struct DisplayCadenceTracker: Sendable {
        private var lastActiveTimestamp: CFTimeInterval?
        private(set) var snapshot = DisplayCadenceSnapshot()

        mutating func note(
            frame: UIKitTimelineDisplayFrame,
            phase: UIKitGridScrollPhase,
            drew: Bool,
            completedAt: CFTimeInterval
        ) {
            guard phase != .idle else {
                lastActiveTimestamp = nil
                return
            }
            let targetInterval = frame.targetTimestamp - frame.timestamp
            if let lastActiveTimestamp {
                let actualInterval = frame.timestamp - lastActiveTimestamp
                if actualInterval > 0, targetInterval > 0 {
                    snapshot.intervalSamples += 1
                    snapshot.intervalTotal += actualInterval
                    snapshot.targetIntervalTotal += targetInterval
                    snapshot.maxInterval = max(snapshot.maxInterval, actualInterval)
                    if actualInterval > targetInterval * 1.5 { snapshot.intervalMisses += 1 }
                }
            }
            lastActiveTimestamp = frame.timestamp
            if drew, frame.targetTimestamp > 0, completedAt > frame.targetTimestamp {
                snapshot.deadlineMisses += 1
            }
        }

        mutating func resetCadence() {
            lastActiveTimestamp = nil
        }

        mutating func resetWindow() {
            snapshot = DisplayCadenceSnapshot()
        }
    }

    struct PresentationTimingSnapshot: Equatable, Sendable {
        var presented = 0
        var dropped = 0
        var late = 0
        var intervalSamples = 0
        var intervalTotal: CFTimeInterval = 0
        var maxInterval: CFTimeInterval = 0
    }

    /// Metal invokes presentation handlers off the main actor. This lock-protected accumulator does bounded
    /// arithmetic only; the main-actor diagnostics window drains it on a later display tick without creating a task.
    final class PresentationTimingAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot = PresentationTimingSnapshot()
        private var previousPresentedTime: CFTimeInterval?

        func note(
            presentedTime: CFTimeInterval?,
            targetTimestamp: CFTimeInterval,
            targetInterval: CFTimeInterval
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard let presentedTime, presentedTime > 0 else {
                snapshot.dropped += 1
                return
            }
            snapshot.presented += 1
            if let previousPresentedTime {
                let interval = presentedTime - previousPresentedTime
                if interval > 0 {
                    snapshot.intervalSamples += 1
                    snapshot.intervalTotal += interval
                    snapshot.maxInterval = max(snapshot.maxInterval, interval)
                }
            }
            self.previousPresentedTime = presentedTime
            if targetTimestamp > 0, targetInterval > 0,
                presentedTime > targetTimestamp + max(0.001, targetInterval * 0.5)
            {
                snapshot.late += 1
            }
        }

        func drain() -> PresentationTimingSnapshot {
            lock.lock()
            defer { lock.unlock() }
            let drained = snapshot
            snapshot = PresentationTimingSnapshot()
            return drained
        }

        func resetCadence() {
            lock.lock()
            previousPresentedTime = nil
            lock.unlock()
        }
    }

    // MARK: - Low-noise render diagnostics

    /// One-second render-loop aggregation window. It logs at `.notice` while the loop runs and stays silent when idle.
    /// Counters cover input coalescing, draws, drawable failures, uploads, deferrals, quality upgrades, and residency.
    @MainActor
    struct RenderPerfWindow {
        private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "MobileGridPerf")

        private var windowStart: CFTimeInterval = 0
        private var scrollEvents = 0
        private var ticks = 0
        private var draws = 0
        private var drawableFailures = 0
        private var uploads = 0
        private var uploadMs: Double = 0
        private var deferredUploads = 0
        private var upgrades = 0
        private var lastVisible = 0
        private var lastMissing = 0
        private var lastResidentBytes = 0
        private var lastResidentCapBytes = 0
        /// Frames this window in which the resident byte/count budget refused an upload (residency saturation).
        private var saturatedDraws = 0
        /// Last frame's RAM-decoded-but-not-GPU-resident visible count (`ramHitGpuMissing`).
        private var lastRamHitGpuMiss = 0
        private var cadence = DisplayCadenceTracker()
        private var presentation = PresentationTimingSnapshot()
        private var cpuPrepMs = 0.0
        private var cpuPrepSamples = 0
        private var maxCpuPrepMs = 0.0
        private var drawableWaitMs = 0.0
        private var drawableWaitSamples = 0
        private var maxDrawableWaitMs = 0.0
        private var frameBoundaryWaitMs = 0.0
        private var maxFrameBoundaryWaitMs = 0.0
        private var rendererEncodeMs = 0.0
        private var rendererEncodeSamples = 0
        private var lastGpuMs: Double?
        private var trackingTicks = 0
        private var draggingTicks = 0
        private var deceleratingTicks = 0
        private var animatingTicks = 0

        mutating func noteScrollEvent() {
            scrollEvents += 1
        }

        /// Preserve the bounded window across short pauses; flushing here could log at scroll-event frequency.
        /// The next active tick publishes once the one-second window expires, excluding idle time from cadence.
        mutating func noteLoopPaused(reason: String) {
            cadence.resetCadence()
        }

        mutating func noteDraw<ID>(
            visible: Int, missing: Int, ramHitGpuMiss: Int, saturated: Bool,
            cache: MetalGridTextureCache<ID>?, cpuPreparationMs: Double,
            drawableWaitMs: Double?, frameBoundaryWaitMs: Double?, rendererEncodeMs: Double?, gpuMs: Double?
        ) {
            draws += 1
            lastVisible = visible
            lastMissing = missing
            lastRamHitGpuMiss = ramHitGpuMiss
            if saturated { saturatedDraws += 1 }
            if let cache {
                uploads += cache.uploadsThisFrame
                uploadMs += cache.uploadMsThisFrame
                deferredUploads += cache.deferredUploadsThisFrame
                upgrades += cache.upgradesThisFrame
                lastResidentBytes = cache.residentBytes
                lastResidentCapBytes = cache.residentByteBudget
            }
            self.cpuPrepMs += cpuPreparationMs
            cpuPrepSamples += 1
            maxCpuPrepMs = max(maxCpuPrepMs, cpuPreparationMs)
            if let drawableWaitMs {
                self.drawableWaitMs += drawableWaitMs
                drawableWaitSamples += 1
                maxDrawableWaitMs = max(maxDrawableWaitMs, drawableWaitMs)
            }
            if let frameBoundaryWaitMs {
                self.frameBoundaryWaitMs += frameBoundaryWaitMs
                maxFrameBoundaryWaitMs = max(maxFrameBoundaryWaitMs, frameBoundaryWaitMs)
            }
            if let rendererEncodeMs {
                self.rendererEncodeMs += rendererEncodeMs
                rendererEncodeSamples += 1
            }
            if let gpuMs { lastGpuMs = gpuMs }
        }

        mutating func notePresentation(_ next: PresentationTimingSnapshot) {
            presentation.presented += next.presented
            presentation.dropped += next.dropped
            presentation.late += next.late
            presentation.intervalSamples += next.intervalSamples
            presentation.intervalTotal += next.intervalTotal
            presentation.maxInterval = max(presentation.maxInterval, next.maxInterval)
        }

        mutating func noteDrawableWait(_ waitMs: Double) {
            drawableWaitMs += waitMs
            drawableWaitSamples += 1
            maxDrawableWaitMs = max(maxDrawableWaitMs, waitMs)
        }

        mutating func noteTick(
            frame: UIKitTimelineDisplayFrame,
            phase: UIKitGridScrollPhase,
            drew: Bool,
            drawableFailed: Bool,
            completedAt: CFTimeInterval
        ) {
            ticks += 1
            if drawableFailed { drawableFailures += 1 }
            cadence.note(frame: frame, phase: phase, drew: drew, completedAt: completedAt)
            switch phase {
            case .idle: break
            case .tracking: trackingTicks += 1
            case .dragging: draggingTicks += 1
            case .decelerating: deceleratingTicks += 1
            case .animating: animatingTicks += 1
            }
            let now = frame.timestamp
            if windowStart == 0 { windowStart = now }
            if now - windowStart >= 1.0 {
                flush(reason: "window")
                windowStart = now
            }
        }

        mutating func flush(reason: String) {
            guard ticks > 0 else { return }
            let (t, d, s, f) = (ticks, draws, scrollEvents, drawableFailures)
            let (u, um, du, up) = (uploads, String(format: "%.2f", uploadMs), deferredUploads, upgrades)
            let (vis, mis, mb) = (lastVisible, lastMissing, lastResidentBytes / 1_048_576)
            let (capMB, sat, ramGpu) = (lastResidentCapBytes / 1_048_576, saturatedDraws, lastRamHitGpuMiss)
            let cadenceSnapshot = cadence.snapshot
            let actualHz = Self.rate(samples: cadenceSnapshot.intervalSamples, total: cadenceSnapshot.intervalTotal)
            let targetHz = Self.rate(
                samples: cadenceSnapshot.intervalSamples, total: cadenceSnapshot.targetIntervalTotal)
            let presentHz = Self.rate(samples: presentation.intervalSamples, total: presentation.intervalTotal)
            let cpu = Self.average(total: cpuPrepMs, samples: cpuPrepSamples)
            let drawable = Self.average(total: drawableWaitMs, samples: drawableWaitSamples)
            let boundary = Self.average(total: frameBoundaryWaitMs, samples: draws)
            let encode = Self.average(total: rendererEncodeMs, samples: rendererEncodeSamples)
            let gpu = lastGpuMs.map { String(format: "%.2f", $0) } ?? "na"
            let phaseTicks = (trackingTicks, draggingTicks, deceleratingTicks, animatingTicks)
            let maxCpu = String(format: "%.2f", maxCpuPrepMs)
            let maxDrawable = String(format: "%.2f", maxDrawableWaitMs)
            let maxBoundary = String(format: "%.2f", maxFrameBoundaryWaitMs)
            let presentationSnapshot = presentation
            let maxPresentationInterval = String(format: "%.2f", presentationSnapshot.maxInterval * 1000)
            Self.logger.notice(
                """
                [MobileGridPerf] \(reason, privacy: .public) ticks=\(t) draws=\(d) scrollEvents=\(s) \
                drawableFail=\(f) uploads=\(u) uploadMs=\(um, privacy: .public) deferred=\(du) upgrades=\(up) \
                visible=\(vis) missing=\(mis) ramGpuMiss=\(ramGpu) residentMB=\(mb)/\(capMB) saturated=\(sat) \
                actualHz=\(actualHz, privacy: .public) targetHz=\(targetHz, privacy: .public) \
                intervalMiss=\(cadenceSnapshot.intervalMisses) deadlineMiss=\(cadenceSnapshot.deadlineMisses) \
                maxIntervalMs=\(String(format: "%.2f", cadenceSnapshot.maxInterval * 1000), privacy: .public) \
                phase=tracking:\(phaseTicks.0),dragging:\(phaseTicks.1),decelerating:\(phaseTicks.2),animating:\(phaseTicks.3) \
                cpuPrepMs=\(cpu, privacy: .public)/\(maxCpu, privacy: .public) \
                drawableWaitMs=\(drawable, privacy: .public)/\(maxDrawable, privacy: .public) \
                frameBoundaryWaitMs=\(boundary, privacy: .public)/\(maxBoundary, privacy: .public) \
                encodeMs=\(encode, privacy: .public) gpuMs=\(gpu, privacy: .public) \
                presented=\(presentationSnapshot.presented) dropped=\(presentationSnapshot.dropped) presentLate=\(presentationSnapshot.late) \
                presentHz=\(presentHz, privacy: .public) maxPresentIntervalMs=\(maxPresentationInterval, privacy: .public)
                """)
            // A visible hitch during grid activity gets its own low-noise [UIHitch] line (1 s throttled via the
            // window) so a `log stream` filtered to [UIHitch] shows both tab transitions AND grid frame stalls.
            if cadenceSnapshot.intervalMisses > 0 || cadenceSnapshot.deadlineMisses > 0 {
                UIHitchLog.frameGap(
                    hitches: cadenceSnapshot.intervalMisses + cadenceSnapshot.deadlineMisses,
                    maxGapMs: cadenceSnapshot.maxInterval * 1000, ticks: ticks, draws: draws)
            }
            scrollEvents = 0
            ticks = 0
            draws = 0
            drawableFailures = 0
            uploads = 0
            uploadMs = 0
            deferredUploads = 0
            upgrades = 0
            saturatedDraws = 0
            cadence.resetWindow()
            presentation = PresentationTimingSnapshot()
            cpuPrepMs = 0
            cpuPrepSamples = 0
            maxCpuPrepMs = 0
            drawableWaitMs = 0
            drawableWaitSamples = 0
            maxDrawableWaitMs = 0
            frameBoundaryWaitMs = 0
            maxFrameBoundaryWaitMs = 0
            rendererEncodeMs = 0
            rendererEncodeSamples = 0
            lastGpuMs = nil
            trackingTicks = 0
            draggingTicks = 0
            deceleratingTicks = 0
            animatingTicks = 0
        }

        private static func average(total: Double, samples: Int) -> String {
            guard samples > 0 else { return "na" }
            return String(format: "%.2f", total / Double(samples))
        }

        private static func rate(samples: Int, total: CFTimeInterval) -> String {
            guard samples > 0, total > 0 else { return "na" }
            return String(format: "%.1f", Double(samples) / total)
        }
    }

    // MARK: - UI hitch diagnostics

    /// Low-noise `[UIHitch]` diagnostics for menu and tab activity. Emits on grid activity transitions and at most
    /// once per second for a render-loop gap over two frames. It never logs per frame.
    @MainActor
    enum UIHitchLog {
        private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "UIHitch")

        static func gridActivity(
            active: Bool, hasWindow: Bool, displayLinkRunning: Bool,
            warmInFlight: Bool, aheadWarmInFlight: Bool, items: Int
        ) {
            logger.notice(
                """
                [UIHitch] event=gridActivity gridActive=\(active) window=\(hasWindow) \
                displayLink=\(displayLinkRunning) warmInFlight=\(warmInFlight) aheadWarm=\(aheadWarmInFlight) \
                items=\(items)
                """)
        }

        static func frameGap(hitches: Int, maxGapMs: Double, ticks: Int, draws: Int) {
            logger.notice(
                """
                [UIHitch] event=gridFrameGap hitches=\(hitches) maxGapMs=\(String(format: "%.0f", maxGapMs), privacy: .public) \
                ticks=\(ticks) draws=\(draws)
                """)
        }
    }
#endif
