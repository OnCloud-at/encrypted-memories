import Foundation
import PhotosCore

/// Guides the person through a large first backup (#275): while it runs, the status shows how to speed it up, and once
/// it completes, it says so once. The rules live here once for iOS, iPadOS and macOS.
public enum BackupFirstBackupGuide {
    /// The persisted step. No stored value means that no backup was seen yet.
    public enum State: String, Sendable, Equatable {
        /// The first status had nothing backed up: this may become a guided first backup once it starts checking after
        /// the scan.
        case candidate
        /// A first backup of at least `largeBackupThreshold` photos runs.
        case running
        /// That backup completed; the status says so until the person leaves the backup settings.
        case completedUnseen
        /// Nothing to guide any more, or the first backup was small or already backed up.
        case done
    }

    /// One global key, removed with the whole app domain on sign-out.
    public static let defaultsKey = "photoBackup.firstBackupGuide.v1"
    /// A first backup with at least this many photos to back up counts as large.
    public static let largeBackupThreshold = 1_000

    /// The next step after the backup reported `status`.
    public static func next(_ state: State?, after status: BackupStatus) -> State? {
        switch state {
        case nil:
            // The first status decides whether this can be a first backup: a library with backed-up photos is none.
            return status.backedUp == 0 ? .candidate : .done
        case .candidate:
            // The first active status after the scan decides, once: when the backup starts checking, it is a large first
            // backup if at least the threshold of photos is to be backed up that Proton did not already hold. Photos this
            // backup uploaded itself, also while the scan ran, count; photos Proton already holds do not. Proton's
            // identity proofs settle during the scan, so a reinstall over a backed-up library ends quietly here. Known
            // limit: when that proof request fails, a reinstall counts as large and shows the hint; it is only a hint.
            // While the photo total is unknown, for example after a scan that failed or stopped, the photos so far are
            // only part of the library: a count that already reaches the threshold starts the guide, but nothing ends
            // the candidate before a scan has counted every photo.
            let totalKnown = status.photoDisplayProgress?.isTotalKnown != false
            if status.phase == .checking || status.phase == .uploading, let target = status.backupTargetCount {
                if target - status.alreadyBackedUp >= largeBackupThreshold { return .running }
                return totalKnown ? .done : .candidate
            }
            // A first pass that is completed or needs attention before it checks anything guides nothing. A later pass on
            // a grown library is no first backup any more.
            return totalKnown && (status.phase == .completed || status.phase == .needsAttention) ? .done : .candidate
        case .running:
            guard status.phase == .completed else { return .running }
            // A pass that completes while the photo total is unknown backed up only the photos found so far. The guide
            // keeps running until a pass completes after a scan has counted every photo.
            guard status.photoDisplayProgress?.isTotalKnown != false else { return .running }
            // Only a completion without omissions or respected deletions that uploaded something is a completed
            // first backup. A library that was already in Proton (for example after a reinstall) ends quietly.
            let plain = status.dismissedFailures == 0 && status.skippedRemoteDeletions == 0
            return plain && status.uploaded > 0 ? .completedUnseen : .done
        case .completedUnseen:
            return status.isActive && status.remainingCount > 0 ? .done : .completedUnseen
        case .done:
            return .done
        }
    }

    /// The next step after the person left the backup settings.
    public static func afterScreenSeen(_ state: State?) -> State? {
        state == .completedUnseen ? .done : state
    }
}

/// Keeps the guide step in the app's preferences.
public final class BackupFirstBackupGuideStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var state: BackupFirstBackupGuide.State? {
        lock.withLock { read() }
    }

    /// Moves the step on after a status and returns the new step. While a sign-out purge is pending, nothing is
    /// written: the purge must not find the key again after it removed the app's preferences.
    @discardableResult
    public func update(with status: BackupStatus) -> BackupFirstBackupGuide.State? {
        lock.withLock {
            guard !BackupLocalDataPurge.isPurgePending(defaults: defaults) else { return read() }
            return write(BackupFirstBackupGuide.next(read(), after: status))
        }
    }

    /// Moves the step on after the person left the backup settings. True when the step changed.
    @discardableResult
    public func screenSeen() -> Bool {
        lock.withLock {
            let before = read()
            guard !BackupLocalDataPurge.isPurgePending(defaults: defaults) else { return false }
            return write(BackupFirstBackupGuide.afterScreenSeen(before)) != before
        }
    }

    private func read() -> BackupFirstBackupGuide.State? {
        defaults.string(forKey: BackupFirstBackupGuide.defaultsKey)
            .flatMap(BackupFirstBackupGuide.State.init(rawValue:))
    }

    private func write(_ state: BackupFirstBackupGuide.State?) -> BackupFirstBackupGuide.State? {
        guard state != read() else { return state }
        defaults.set(state?.rawValue, forKey: BackupFirstBackupGuide.defaultsKey)
        // Sign-out may arm its purge between the check before this write and the write itself; the key then goes too.
        // Sign-out removes the preferences first and sets the purge flag after; a write in that short window stays.
        if BackupLocalDataPurge.isPurgePending(defaults: defaults) {
            defaults.removeObject(forKey: BackupFirstBackupGuide.defaultsKey)
        }
        return state
    }
}
