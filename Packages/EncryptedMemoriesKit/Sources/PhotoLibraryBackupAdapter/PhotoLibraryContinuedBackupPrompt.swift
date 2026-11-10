import Foundation
import PhotosCore
import UploadCore

/// When the app offers to keep the backup running in the background with a continued processing task (#1108). It asks
/// when the backup that runs would take about five minutes or more: such a backlog is not done when the person leaves
/// the app, because the short background grace ends after about 26 s.
///
/// The time is `max(photos × secondsPerItem, bytes ÷ bytesPerSecond)`. Both rates come from the measured foreground
/// backup on Wi-Fi (about 20 files per minute and 2.3 MB per second), rounded to the slower side. Many small photos ask
/// by their count; few large videos ask by their estimated volume.
public enum PhotoLibraryContinuedBackupPrompt {
    /// Seconds per photo: the measured foreground backup did about 20 files per minute.
    public static let secondsPerItem = 3.0
    /// Bytes per second: the measured foreground backup sent about 2.3 MB/s, a background window about 2.9 MB/s.
    public static let bytesPerSecond = 2_000_000.0
    /// The app asks when the estimated time left reaches this many seconds.
    public static let askAfterSeconds = 300.0
    /// The marker in the app's standard defaults, which sign-out clears: the person answered for the backlog that is
    /// still owed.
    public static let askedMarkerKey = "photoBackup.continuedPrompt.asked.v1"

    /// What the app allows apart from the place: the place's own calm and cover rules live in `Asker`.
    public struct Situation: Sendable, Equatable {
        /// A continued processing task already runs.
        public let isTaskActive: Bool
        /// The person already answered for the backlog that is still owed.
        public let wasAsked: Bool

        public init(isTaskActive: Bool, wasAsked: Bool) {
            self.isTaskActive = isTaskActive
            self.wasAsked = wasAsked
        }
    }

    /// The rules of one place that shows the question (#1108): it asks only when its scene has been active and
    /// uncovered for `calmDelay`, while it holds the shared claim, and once per backlog. The view only shows the alert
    /// and reports the scene, the cover and the answer.
    @MainActor
    public final class Asker {
        /// What the place does now.
        public enum Next: Equatable {
            /// Show the question.
            case ask
            /// Ask again after this time; the calm time has not passed.
            case wait(Duration)
            /// Do not ask now.
            case none
        }

        /// Whether the person answered for the backlog that is still owed, kept by the app.
        public struct Marker {
            public let isSet: () -> Bool
            public let set: (Bool) -> Void

            public init(isSet: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
                self.isSet = isSet
                self.set = set
            }

            /// The marker under `askedMarkerKey` in `defaults`.
            public static func stored(in defaults: UserDefaults = .standard) -> Marker {
                Marker(
                    isSet: { defaults.bool(forKey: askedMarkerKey) },
                    set: {
                        $0 ? defaults.set(true, forKey: askedMarkerKey) : defaults.removeObject(forKey: askedMarkerKey)
                    })
            }
        }

        /// How long the scene is active and the place uncovered before it may ask: HIG Alerts advise against an alert
        /// at launch, and a question right after a sheet closes would interrupt.
        public static let calmDelay: Duration = .seconds(2)

        private let claim: Claim
        private let marker: Marker
        private let calmDelay: Duration
        private let place = UUID()
        /// Since when the scene is active and the place uncovered; nil while it is not.
        private var calmSince: ContinuousClock.Instant?
        private var isActive = false
        private var isCovered = false
        /// The question is shown by this place.
        public private(set) var isPresenting = false

        public init(claim: Claim = .shared, marker: Marker, calmDelay: Duration = Asker.calmDelay) {
            self.claim = claim
            self.marker = marker
            self.calmDelay = calmDelay
        }

        public func sceneBecameActive(at now: ContinuousClock.Instant) {
            isActive = true
            if !isCovered { calmSince = now }
        }

        /// The scene went to the background while the question showed: that counts as "Not Now".
        public func sceneEnteredBackground() {
            isActive = false
            calmSince = nil
            if isPresenting { marker.set(true) }
            stopPresenting()
        }

        /// Something covers the place, or no longer does. A cover over the question closes it without an answer; the
        /// end of a cover starts the calm time again.
        public func coverChanged(isCovered covered: Bool, at now: ContinuousClock.Instant) {
            guard covered != isCovered else { return }
            isCovered = covered
            if covered {
                calmSince = nil
                stopPresenting()
            } else if isActive {
                calmSince = now
            }
        }

        /// The backup state changed. A drained backlog may be asked about again.
        public func backupChanged(_ status: BackupStatus, isSyncing: Bool) {
            if backlogDrained(status, isSyncing: isSyncing) { marker.set(false) }
        }

        public func next(
            _ status: BackupStatus, estimatedBytes: Int64?, isTaskActive: Bool, at now: ContinuousClock.Instant
        ) -> Next {
            guard !isPresenting, isActive, !isCovered, let calmSince else { return .none }
            let situation = Situation(isTaskActive: isTaskActive, wasAsked: marker.isSet())
            guard shouldAsk(status, estimatedBytes: estimatedBytes, in: situation) else { return .none }
            let calmIn = calmDelay - (now - calmSince)
            if calmIn > .zero { return .wait(calmIn) }
            guard claim.claim(place) else { return .none }
            isPresenting = true
            return .ask
        }

        /// Either answer closes the question for this backlog. Returns whether the person chose to continue.
        public func answered(accepted: Bool) -> Bool {
            marker.set(true)
            stopPresenting()
            return accepted
        }

        private func stopPresenting() {
            isPresenting = false
            claim.release(place)
        }
    }

    /// Only one place shows the question at a time, across every window of the app: HIG Alerts allow one alert at a
    /// time, and two windows side by side must not both ask.
    @MainActor
    public final class Claim {
        public static let shared = Claim()
        private var holder: UUID?

        public init() {}

        /// Takes the claim for `place` when nobody holds it; the holder keeps it.
        public func claim(_ place: UUID) -> Bool {
            guard holder == nil || holder == place else { return false }
            holder = place
            return true
        }

        /// Ends the claim of `place`; another place's claim stays.
        public func release(_ place: UUID) {
            if holder == place { holder = nil }
        }
    }

    /// From this many photos left, the count alone reaches the time; no volume estimate is needed.
    public static var itemsThatAlwaysAsk: Int { Int((askAfterSeconds / secondsPerItem).rounded(.up)) }

    /// The volume decides only for a backlog that its count does not decide.
    public static func needsVolume(_ status: BackupStatus) -> Bool {
        status.remainingCount > 0 && status.remainingCount < itemsThatAlwaysAsk
    }

    /// A pass checks or uploads, and the estimated time left reaches `askAfterSeconds`. Without a volume estimate, for
    /// example after a failed catalog read, the count alone decides.
    public static func isWorthAsking(_ status: BackupStatus, estimatedBytes: Int64?) -> Bool {
        guard status.phase == .checking || status.phase == .uploading else { return false }
        let byCount = Double(max(0, status.remainingCount)) * secondsPerItem
        let byVolume = Double(max(0, estimatedBytes ?? 0)) / bytesPerSecond
        return max(byCount, byVolume) >= askAfterSeconds
    }

    public static func shouldAsk(_ status: BackupStatus, estimatedBytes: Int64?, in situation: Situation) -> Bool {
        !situation.isTaskActive && !situation.wasAsked && isWorthAsking(status, estimatedBytes: estimatedBytes)
    }

    /// The backlog the person answered for is done: the queue is projected, no pass runs and no work is owed. Only then
    /// may the app ask again. A status that is not projected yet, as at a cold start, says nothing about the queue.
    public static func backlogDrained(_ status: BackupStatus, isSyncing: Bool) -> Bool {
        status.totalConsidered != nil && !isSyncing && !status.hasOutstandingWork
    }
}

/// An upper-side estimate of the bytes that photos still to back up will send, from what the catalog knows before a file
/// is read: PhotoKit offers no official file size before the export (PhotoBackupAssetPlan).
public enum PhotoLibraryContinuedBackupVolume {
    /// Assumption, upper side for HEIC and JPEG: a 12 MP HEIC has about 2–3 MB (0.2 B/px), a 12 MP JPEG 4–5 MB. The
    /// owner's backup log sent a median of 18 MB and a tenth percentile of 6.3 MB per uploaded photo or video.
    static let photoBytesPerPixel = 0.5
    /// Assumption: the paired video of a Live Photo, about 3 s at 1080p.
    static let livePhotoVideoBytes: Int64 = 4_000_000
    /// Assumption, unverified: iOS Settings › Camera › Record Video lists about 400 MB per minute for 4K at 60 fps.
    static let ultraHighDefinitionVideoBytesPerSecond = 6_700_000.0
    /// Assumption, unverified: about 90 MB per minute for 1080p at 60 fps.
    static let highDefinitionVideoBytesPerSecond = 1_500_000.0
    /// Assumption, unverified: about 40 MB per minute for 720p at 30 fps.
    static let smallVideoBytesPerSecond = 700_000.0
    /// An item without a catalog row counts as a 12 MP photo.
    static let unknownItemBytes: Int64 = 6_000_000

    public static func bytes(of entry: PhotoLibraryCatalogEntry?) -> Int64 {
        guard let entry else { return unknownItemBytes }
        switch entry.mediaKind {
        case .image:
            let pixels = Double(max(0, entry.pixelWidth)) * Double(max(0, entry.pixelHeight))
            let photo = saturated(pixels * photoBytesPerPixel)
            return entry.isLivePhoto ? sum(photo, livePhotoVideoBytes) : photo
        case .video:
            let longSide = max(entry.pixelWidth, entry.pixelHeight)
            let rate =
                longSide >= 3_840
                ? ultraHighDefinitionVideoBytesPerSecond
                : longSide >= 1_920 ? highDefinitionVideoBytesPerSecond : smallVideoBytesPerSecond
            return saturated(max(0, entry.durationSeconds) * rate)
        }
    }

    public static func bytes(of entries: [PhotoLibraryCatalogEntry?]) -> Int64 {
        entries.reduce(0) { sum($0, bytes(of: $1)) }
    }

    private static func saturated(_ value: Double) -> Int64 {
        guard value.isFinite else { return value > 0 ? .max : 0 }
        guard value < Double(Int64.max) else { return .max }
        return Int64(max(0, value.rounded(.down)))
    }

    private static func sum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}
