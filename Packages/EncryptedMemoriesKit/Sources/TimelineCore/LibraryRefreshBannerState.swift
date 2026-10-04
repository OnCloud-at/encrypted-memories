import Foundation

/// A message of the library refresh banner. Hosts map each case to localized text.
public enum LibraryRefreshBannerMessage: Sendable, Equatable {
    case refreshing
    case refreshingAfterUpload
    case waitingForRefresh
    case refreshed
    case uploaded
    case refreshFailed
    case notYetIndexed

    public enum Tone: Sendable, Equatable {
        case working
        case success
        case failure
    }

    public var tone: Tone {
        switch self {
        case .refreshing, .refreshingAfterUpload, .waitingForRefresh: return .working
        case .refreshed, .uploaded: return .success
        case .refreshFailed, .notYetIndexed: return .failure
        }
    }

    /// Results leave after a short delay. Progress stays while its refresh runs. An indexing warning stays until a
    /// later refresh route replaces it; a routine refresh success alone does not prove the uploaded photo appeared.
    var dismissesAutomatically: Bool {
        switch self {
        case .refreshed, .uploaded, .refreshFailed: return true
        case .refreshing, .refreshingAfterUpload, .waitingForRefresh, .notYetIndexed: return false
        }
    }
}

/// Pure state of the library refresh banner and the refresh gate that serializes the host refresh routes.
/// The host runs the refreshes and the dismissal timers; this type decides which message the banner shows.
public struct LibraryRefreshBannerState: Sendable, Equatable {
    /// One automatic dismissal. The host waits `delay` and then passes it back to `dismiss(_:)`.
    public struct Dismissal: Sendable, Equatable {
        public let delay: Duration
        let generation: UInt64
    }

    public static let dismissalDelay: Duration = .seconds(2)

    /// A refresh is running. Remote change polling and manual refreshes wait while it is set.
    public private(set) var isBusy = false
    public private(set) var message: LibraryRefreshBannerMessage?
    /// Identifies the current message, so a timer of an earlier message never removes a later one.
    private var generation: UInt64 = 0
    /// The dismissal of the current message arrived while a refresh was running. It applies when the refresh ends.
    private var dismissalIsDue = false

    public init() {}

    // MARK: - Manual refresh

    /// Starts a menu refresh. Returns `false` when another refresh is already running.
    public mutating func beginManualRefresh() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        show(.refreshing)
        return true
    }

    public mutating func finishManualRefresh(succeeded: Bool) -> Dismissal? {
        isBusy = false
        return show(succeeded ? .refreshed : .refreshFailed)
    }

    // MARK: - Manual upload refresh

    public mutating func beginUploadRefresh() {
        isBusy = true
        show(.refreshingAfterUpload)
    }

    public mutating func waitForUploadRefresh() {
        show(.waitingForRefresh)
    }

    /// Ends the refresh after a manual upload. Without the uploaded photo, the indexing warning stays.
    public mutating func finishUploadRefresh(found: Bool) -> Dismissal? {
        isBusy = false
        return show(found ? .uploaded : .notYetIndexed)
    }

    // MARK: - Backup upload refresh

    public mutating func beginBackupUploadRefresh() {
        isBusy = true
        show(.refreshing)
    }

    public mutating func applyBackupUploadRefresh(_ decision: TimelineRefreshConvergenceDecision) -> Dismissal? {
        switch decision {
        case .succeeded:
            isBusy = false
            return show(.refreshed)
        case .retry:
            return show(.waitingForRefresh)
        case .notYetVisible:
            isBusy = false
            return show(.notYetIndexed)
        case .failed:
            isBusy = false
            return show(.refreshFailed)
        case .cancelled:
            isBusy = false
            clear()
            return nil
        }
    }

    // MARK: - Remote change refresh

    /// Starts a silent refresh for a remote library change. Returns `false` when another refresh is running.
    public mutating func beginRemoteRefresh() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    /// Ends a silent refresh. A success removes an earlier refresh failure, because the library is current again.
    /// A dismissal that arrived during the refresh applies now.
    public mutating func finishRemoteRefresh(succeeded: Bool) {
        isBusy = false
        if dismissalIsDue || (succeeded && message == .refreshFailed) {
            clear()
        }
    }

    // MARK: - Shared transitions

    /// Removes the banner when the Drive scope is lost and the account model takes over.
    public mutating func loseScopeAccess() {
        isBusy = false
        clear()
    }

    /// Removes the message of `dismissal` unless a later message replaced it. While a refresh runs, the dismissal
    /// waits for the end of that refresh.
    public mutating func dismiss(_ dismissal: Dismissal) {
        guard dismissal.generation == generation, message != nil else { return }
        if isBusy {
            dismissalIsDue = true
        } else {
            clear()
        }
    }

    @discardableResult
    private mutating func show(_ next: LibraryRefreshBannerMessage) -> Dismissal? {
        generation &+= 1
        dismissalIsDue = false
        message = next
        return next.dismissesAutomatically ? Dismissal(delay: Self.dismissalDelay, generation: generation) : nil
    }

    private mutating func clear() {
        generation &+= 1
        dismissalIsDue = false
        message = nil
    }
}
