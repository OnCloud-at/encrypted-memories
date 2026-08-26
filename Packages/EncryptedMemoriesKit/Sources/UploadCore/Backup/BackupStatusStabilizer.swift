import Foundation

/// Time-aware hysteresis over `BackupStatusPresentation` so the backup row reads calmly.
///
/// Active phases intentionally say what is happening (scanning, checking, or uploading), but may
/// cycle many times a second while a drain is in flight. This stabilizer dwells that phase: once the
/// displayed phase changes it will not change again for `dwell`, so the row switches text at most
/// about once a second. Numeric progress within an unchanged subtitle passes through immediately,
/// except for a shrinking denominator: stale queue rows are removed while their sources are checked,
/// so that total waits for a short quiet period and then updates once instead of counting down every
/// second. Any structural change, such as entering or leaving active or reaching a terminal, paused, or attention
/// state - applies at once so nothing important is delayed.
///
/// It is a pure value type driven by an injected clock: the caller feeds each incoming presentation
/// via `ingest(_:now:)`, renders `Decision.display`, and - when `Decision.wakeAt` is non-nil -
/// schedules one `wake(now:)` at that time to apply a deferred switch. No repeating timer is used.
public struct BackupStatusStabilizer: Sendable {
    public struct Decision: Sendable, Equatable {
        /// The presentation to show right now.
        public var display: BackupStatusPresentation
        /// If non-nil, the caller should call `wake(now:)` once at this instant to apply a subtitle
        /// change that is currently being held back. nil = nothing pending.
        public var wakeAt: Date?
    }

    /// Minimum time the active subtitle stays put before it may change again.
    public let dwell: TimeInterval
    /// Quiet period required before a decreasing active backup total becomes visible.
    public let denominatorDwell: TimeInterval

    private var displayed: BackupStatusPresentation?
    private var latestIncoming: BackupStatusPresentation?
    /// When the currently-displayed active subtitle was last applied.
    private var subtitleAppliedAt: Date?
    private var pendingDenominator: Int?
    private var denominatorDueAt: Date?

    public init(dwell: TimeInterval = 1.2, denominatorDwell: TimeInterval = 2.5) {
        self.dwell = max(0, dwell)
        self.denominatorDwell = max(0, denominatorDwell)
    }

    /// Feed the newest presentation and get what to display now.
    public mutating func ingest(_ incoming: BackupStatusPresentation, now: Date) -> Decision {
        latestIncoming = incoming
        return evaluate(now: now)
    }

    /// Re-evaluate a previously-held switch (call once at the `wakeAt` the last decision returned).
    public mutating func wake(now: Date) -> Decision {
        evaluate(now: now)
    }

    /// The presentation currently on screen, if any (nil before the first ingest).
    public var current: BackupStatusPresentation? { displayed }

    private mutating func evaluate(now: Date) -> Decision {
        guard let incoming = latestIncoming else {
            return Decision(display: displayed ?? Self.restingIdle, wakeAt: nil)
        }
        guard let current = displayed else {
            apply(incoming, at: now)
            return Decision(display: incoming, wakeAt: nil)
        }

        // Structural change - entering/leaving active, or any non-active target (completed, paused,
        // waiting, attention, idle) - is never delayed.
        if !incoming.isActive || !current.isActive {
            clearPendingDenominator()
            apply(incoming, at: now)
            return Decision(display: incoming, wakeAt: nil)
        }

        // Both active and the calm subtitle is unchanged: let numbers/progress through immediately.
        if Self.sameSubtitle(current, incoming) {
            return applyActiveNumbers(incoming, over: current, now: now)
        }

        // Both active but the subtitle differs: hold the current coherent presentation until the
        // dwell elapses, so the visible text switches at most once per `dwell`.
        let due = (subtitleAppliedAt ?? now).addingTimeInterval(dwell)
        if now >= due {
            subtitleAppliedAt = now
            return applyActiveNumbers(incoming, over: current, now: now)
        }
        let numeric = applyActiveNumbers(current, over: current, now: now, latestTotal: incoming.total)
        return Decision(display: numeric.display, wakeAt: Self.earlier(due, numeric.wakeAt))
    }

    /// Applies same-phase numeric progress immediately while coalescing only a shrinking total. The
    /// queue total may legitimately fall as missing/stale sources are removed; resetting the deadline
    /// for each new value makes the UI wait for quiet and then publish one final denominator.
    private mutating func applyActiveNumbers(
        _ candidate: BackupStatusPresentation,
        over current: BackupStatusPresentation,
        now: Date,
        latestTotal: Int? = nil
    ) -> Decision {
        let targetTotal = latestTotal ?? candidate.total
        var output = candidate

        guard targetTotal > 0, targetTotal < current.total else {
            clearPendingDenominator()
            displayed = output
            return Decision(display: output, wakeAt: nil)
        }

        if pendingDenominator != targetTotal {
            pendingDenominator = targetTotal
            denominatorDueAt = now.addingTimeInterval(denominatorDwell)
        }
        if let due = denominatorDueAt, now < due {
            output.total = current.total
            displayed = output
            return Decision(display: output, wakeAt: due)
        }

        output.total = targetTotal
        clearPendingDenominator()
        displayed = output
        return Decision(display: output, wakeAt: nil)
    }

    private mutating func apply(_ presentation: BackupStatusPresentation, at now: Date) {
        displayed = presentation
        subtitleAppliedAt = presentation.isActive ? now : nil
    }

    private mutating func clearPendingDenominator() {
        pendingDenominator = nil
        denominatorDueAt = nil
    }

    private static func earlier(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?): min(lhs, rhs)
        case (let lhs?, nil): lhs
        case (nil, let rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func sameSubtitle(_ a: BackupStatusPresentation, _ b: BackupStatusPresentation) -> Bool {
        // Dwell on the phase (headline) + icon; the numeric subtitle and upload percentage within an
        // unchanged phase pass through immediately (they advance on their own).
        a.headlineKey == b.headlineKey && a.accessory == b.accessory
    }

    private static let restingIdle = BackupStatusPresentation(BackupStatus())
}
