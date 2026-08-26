#if canImport(UIKit)
    import MetalGridTextureCore
    import os
    import QuartzCore

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
        /// Timestamp of the previous tick and the count of inter-tick gaps over two frames (33 ms). Reset when the
        /// loop stops so a resumed loop does not count its idle interval as a hitch.
        private var lastTickAt: CFTimeInterval = 0
        private var hitches = 0
        private var maxGapMs: Double = 0

        mutating func noteScrollEvent() {
            scrollEvents += 1
        }

        /// The loop stopped (idle or suspended) - forget the last tick time so the next run's first gap is not
        /// measured against a stale timestamp.
        mutating func noteLoopStopped() {
            lastTickAt = 0
        }

        mutating func noteDraw<ID>(
            visible: Int, missing: Int, ramHitGpuMiss: Int, saturated: Bool,
            cache: MetalGridTextureCache<ID>?
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
        }

        mutating func noteTick(drawableFailed: Bool) {
            ticks += 1
            if drawableFailed { drawableFailures += 1 }
            let now = CACurrentMediaTime()
            if lastTickAt != 0 {
                let gapMs = (now - lastTickAt) * 1000
                if gapMs > 33 {
                    hitches += 1
                    maxGapMs = max(maxGapMs, gapMs)
                }
            }
            lastTickAt = now
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
            let (hit, gap) = (hitches, String(format: "%.0f", maxGapMs))
            Self.logger.notice(
                """
                [MobileGridPerf] \(reason, privacy: .public) ticks=\(t) draws=\(d) scrollEvents=\(s) \
                drawableFail=\(f) uploads=\(u) uploadMs=\(um, privacy: .public) deferred=\(du) upgrades=\(up) \
                visible=\(vis) missing=\(mis) ramGpuMiss=\(ramGpu) residentMB=\(mb)/\(capMB) saturated=\(sat) \
                hitches=\(hit) maxGapMs=\(gap, privacy: .public)
                """)
            // A visible hitch during grid activity gets its own low-noise [UIHitch] line (1 s throttled via the
            // window) so a `log stream` filtered to [UIHitch] shows both tab transitions AND grid frame stalls.
            if hitches > 0 {
                UIHitchLog.frameGap(hitches: hitches, maxGapMs: maxGapMs, ticks: ticks, draws: draws)
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
            hitches = 0
            maxGapMs = 0
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
