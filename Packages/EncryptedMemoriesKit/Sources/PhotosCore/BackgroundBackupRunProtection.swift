import Foundation

/// Tracks the processing windows that still protect a particular controller's backup run.
@MainActor
public final class BackgroundBackupRunProtection {
    public static let shared = BackgroundBackupRunProtection()

    private struct Hold {
        weak var owner: AnyObject?
        let runID: String
    }

    private var holds: [UUID: Hold] = [:]

    #if DEBUG
        public var onHoldForTesting: (@MainActor (UUID) -> Void)?
        public var onReleaseAttemptForTesting: (@MainActor (UUID) -> Void)?
    #endif

    public init() {}

    /// Each processing window gets its own token, even when two windows hold the same run.
    public func hold(owner: AnyObject, runID: String) -> UUID {
        let token = UUID()
        holds[token] = Hold(owner: owner, runID: runID)
        #if DEBUG
            onHoldForTesting?(token)
        #endif
        return token
    }

    /// A completed, expired or cancelled window releases only its own token. Repeated releases do nothing.
    public func release(_ token: UUID) {
        #if DEBUG
            onReleaseAttemptForTesting?(token)
        #endif
        holds.removeValue(forKey: token)
    }

    public func isProtected(owner: AnyObject, runID: String) -> Bool {
        holds.values.contains { $0.owner === owner && $0.runID == runID }
    }
}

/// The protection of one holder, such as an OS background window or a continued processing task. It protects at most one
/// run at a time: holding a new run releases the run before.
@MainActor
public final class BackgroundBackupRunHold {
    private let protection: BackgroundBackupRunProtection
    /// Runs after each new hold, for example to end a short grace that the holder now replaces.
    private let onHold: @MainActor () -> Void
    private var token: UUID?

    public init(protection: BackgroundBackupRunProtection = .shared, onHold: @escaping @MainActor () -> Void = {}) {
        self.protection = protection
        self.onHold = onHold
    }

    /// The run that this holder protects now.
    public private(set) var heldRunID: String?

    /// Protects `runID` of `owner`. Holding the run that is already held changes nothing.
    public func hold(owner: AnyObject, runID: String) {
        guard heldRunID != runID else { return }
        release()
        token = protection.hold(owner: owner, runID: runID)
        heldRunID = runID
        onHold()
    }

    /// Ends this holder's protection. Repeated releases do nothing.
    public func release() {
        if let token { protection.release(token) }
        token = nil
        heldRunID = nil
    }
}
