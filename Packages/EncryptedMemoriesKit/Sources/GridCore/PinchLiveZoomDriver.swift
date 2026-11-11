// Continuous pinch across adjacent detents. `continuousLevel` is authoritative; the active segment follows
// the finger and settles to the nearest detent on release. The host clamps the driver to the eligible band.

package struct PinchLiveZoomDriver: Sendable {
    package enum Phase: Equatable, Sendable {
        case idle
        case scrub  // fingers down, segmentQ follows the finger 1:1 across detents
        case settling  // fingers up, velocity-aware ramp of the active segment to its nearest detent
        case committed  // terminal: landed on `finalLevel`
    }

    /// What the host needs after a live sample: the active adjacent segment + its scrub position.
    package struct Update: Equatable {
        package var segmentSource: Int  // denser (higher index) interval end => shown at segmentQ = 0
        package var segmentTarget: Int  // larger-tile (lower index) end     => shown at segmentQ = 1
        package var segmentQ: Double
        package var hasSegment: Bool  // false before the first move clears the rest dead-band

        package init(segmentSource: Int, segmentTarget: Int, segmentQ: Double, hasSegment: Bool) {
            self.segmentSource = segmentSource
            self.segmentTarget = segmentTarget
            self.segmentQ = segmentQ
            self.hasSegment = hasSegment
        }
    }

    package private(set) var phase: Phase = .idle
    package private(set) var startLevel = 0
    package private(set) var chainLo = 0
    package private(set) var chainHi = 0
    package private(set) var seg = 0  // current interval index: active interval = [seg, seg+1]
    package private(set) var segmentQ: Double = 0
    package private(set) var directionResolved = false
    package private(set) var velocityQPerSecond: Double = 0
    package private(set) var settleTargetQ: Double = 1
    package private(set) var finalLevel = 0  // the detent the gesture lands on (set on commit)
    package private(set) var chainable = false  // false for a degenerate band (lo == hi) => driver stays inert

    private var lastX: Double = 0

    package var tuning = GridTransitionTuning.default

    package init(tuning: GridTransitionTuning = .default) { self.tuning = tuning }

    package var segmentSource: Int { seg + 1 }
    package var segmentTarget: Int { seg }
    package var isActive: Bool { phase == .scrub || phase == .settling }
    package var isSelfAdvancing: Bool { phase == .settling }  // only the post-release settle self-advances (no capture)
    package var isCommitted: Bool { phase == .committed }

    /// Begin a chaining gesture on `startLevel`, bounded to the eligible band `[chainLo, chainHi]` (the host's
    /// contiguous focusRowRelayout run). The first interval brackets `startLevel`; the start detent is shown
    /// until the finger clears the rest dead-band.
    package mutating func begin(startLevel: Int, chainLo: Int, chainHi: Int) {
        self.startLevel = startLevel
        self.chainLo = min(chainLo, startLevel)
        self.chainHi = max(chainHi, startLevel)
        chainable = self.chainHi > self.chainLo
        seg = min(max(self.chainLo, startLevel), max(self.chainLo, self.chainHi - 1))
        segmentQ = chainable ? Double(seg + 1) - Double(startLevel) : 0
        directionResolved = false
        velocityQPerSecond = 0
        settleTargetQ = 1
        finalLevel = startLevel
        lastX = Double(startLevel)
        phase = .scrub
    }

    /// Feed a live pinch sample. Picks the active interval from the (band-clamped) position with detent
    /// hysteresis, and sets `segmentQ` 1:1. Returns the active segment for the host to (re)build + scrub.
    @discardableResult
    package mutating func update(continuousLevel rawX: Double, dt: Double) -> Update {
        guard phase == .scrub, chainable else {  // The host routes an ineligible band to reflow.
            return Update(
                segmentSource: segmentSource, segmentTarget: segmentTarget, segmentQ: segmentQ,
                hasSegment: directionResolved && chainable)
        }
        let x = min(Double(chainHi), max(Double(chainLo), rawX))  // can't chain past the eligible band

        // recent pinch velocity from the GLOBAL position (continuous across detent crossings, unlike segmentQ).
        if dt > 1e-6 {
            let inst = abs(x - lastX) / dt
            velocityQPerSecond += tuning.pinchVelocityEmaAlpha * (inst - velocityQPerSecond)
        }
        lastX = x

        if !directionResolved {
            if abs(x - Double(startLevel)) < tuning.pinchDirectionResolveQ {
                // rest dead-band: hold the start detent, no segment engaged yet
                return Update(
                    segmentSource: segmentSource, segmentTarget: segmentTarget, segmentQ: segmentQ, hasSegment: false)
            }
            directionResolved = true
        }

        // Move the active interval toward x with hysteresis, one detent at a time (handles a fast multi-level
        // flick: x can jump several intervals in one update).
        var guardIter = 0
        while seg > chainLo, Double(seg) - x > tuning.pinchDetentHysteresisQ {
            seg -= 1
            guardIter += 1
            if guardIter > 64 { break }
        }
        while seg < chainHi - 1, x - Double(seg + 1) > tuning.pinchDetentHysteresisQ {
            seg += 1
            guardIter += 1
            if guardIter > 64 { break }
        }

        segmentQ = min(1, max(0, Double(seg + 1) - x))
        return Update(segmentSource: segmentSource, segmentTarget: segmentTarget, segmentQ: segmentQ, hasSegment: true)
    }

    /// Advance the post-release settle on the driver's own clock. No-op while scrubbing (a still finger keeps
    /// the grid still). Speed respects recent pinch velocity, clamped to [min, max] q/s.
    @discardableResult
    package mutating func advance(dt: Double) -> Double {
        guard dt > 0, phase == .settling else { return segmentQ }
        let speed = max(
            tuning.pinchAutoCompleteMinQPerSecond, min(tuning.pinchAutoCompleteMaxQPerSecond, velocityQPerSecond))
        if segmentQ < settleTargetQ {
            segmentQ = min(settleTargetQ, segmentQ + speed * dt)
        } else if segmentQ > settleTargetQ {
            segmentQ = max(settleTargetQ, segmentQ - speed * dt)
        }
        if abs(segmentQ - settleTargetQ) <= 1e-6 {
            segmentQ = settleTargetQ
            finalLevel = settleTargetQ >= 0.5 ? segmentTarget : segmentSource
            phase = .committed
        }
        return segmentQ
    }

    /// Fingers up. Settle the active segment to its nearest detent (by the global position, via `segmentQ`).
    /// Returns the detent the gesture will land on. No hard snap; velocity-aware ramp in `advance`.
    @discardableResult
    package mutating func release(cancelled: Bool = false) -> Int {
        guard phase == .scrub else { return finalLevel }
        // cancelled gestures also settle to nearest (graceful) - there is no abrupt revert.
        _ = cancelled
        if !directionResolved {
            settleTargetQ = segmentQ  // An unmoved gesture stays at its start detent.
            finalLevel = startLevel
        } else if segmentQ >= tuning.pinchReleaseCommitQ {
            settleTargetQ = 1
            finalLevel = segmentTarget
        } else {
            settleTargetQ = 0
            finalLevel = segmentSource
        }
        phase = .settling
        return finalLevel
    }

    /// A sub-dead-band but directional pinch should not be inert. Seed the adjacent segment at the start
    /// detent, then run the normal post-release settle toward that direction at click-like speed.
    /// `direction < 0` means toward lower levels (larger thumbnails / pinch-in); `direction > 0` means toward
    /// higher levels (denser thumbnails / pinch-out).
    @discardableResult
    package mutating func releaseTowardAdjacent(direction: Int, cancelled: Bool = false) -> Update {
        let step = direction < 0 ? -1 : (direction > 0 ? 1 : 0)
        guard phase == .scrub, chainable, !cancelled, step != 0,
            step < 0 ? startLevel > chainLo : startLevel < chainHi
        else {
            _ = release(cancelled: cancelled)
            return Update(
                segmentSource: segmentSource, segmentTarget: segmentTarget, segmentQ: segmentQ, hasSegment: false)
        }
        let target = startLevel + step

        if step < 0 {
            // Interval [target, startLevel]: startLevel is the source end (q=0), target is q=1.
            seg = target
            segmentQ = 0
            settleTargetQ = 1
        } else {
            // Interval [startLevel, target]: startLevel is the target end (q=1), target is q=0.
            seg = startLevel
            segmentQ = 1
            settleTargetQ = 0
        }
        directionResolved = true
        finalLevel = target
        velocityQPerSecond = max(velocityQPerSecond, 1000.0 / max(1.0, tuning.clickDurationMs))
        phase = .settling
        return Update(segmentSource: segmentSource, segmentTarget: segmentTarget, segmentQ: segmentQ, hasSegment: true)
    }

    package mutating func reset() { self = PinchLiveZoomDriver(tuning: tuning) }
}
