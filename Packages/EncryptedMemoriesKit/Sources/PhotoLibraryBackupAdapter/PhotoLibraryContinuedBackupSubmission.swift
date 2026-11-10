import Foundation
import PhotosCore

/// The one submit point of the continued backup task (#1108). Only the person's "Continue" in the continued-backup
/// prompt calls it, and it submits only from the foreground, while the backup owes work and no task of this app runs.
/// The platform adapter supplies the scheduler: `register` registers the launch handler of one identifier; `blocking`
/// sends its request at once (before iOS 27), and `offMainThread` gives the iOS 27 call, which must not run on the main
/// thread. Both go through one `BackgroundTaskRequestSubmitter`.
@MainActor
public final class PhotoLibraryContinuedBackupSubmission {
    private let isSceneActive: @MainActor () -> Bool
    private let makeIdentifier: @MainActor () -> String
    private let register: @MainActor (String) -> Bool
    private let blocking: @MainActor (String) throws -> Void
    private let offMainThread: @MainActor (String) -> (@Sendable () async throws -> Void)?
    private let log: BackgroundWorkLog
    /// Lives as long as this submission: on iOS 27 the request is sent and answered later, off the main thread. The
    /// continued task is never cancelled, so the submitter needs no cancel.
    private let submitter = BackgroundTaskRequestSubmitter()
    /// The identifier of the task that is submitted or runs. One task at a time.
    private var activeIdentifier: String?

    public init(
        isSceneActive: @escaping @MainActor () -> Bool,
        makeIdentifier: @escaping @MainActor () -> String,
        register: @escaping @MainActor (String) -> Bool,
        blocking: @escaping @MainActor (String) throws -> Void,
        offMainThread: @escaping @MainActor (String) -> (@Sendable () async throws -> Void)?,
        log: BackgroundWorkLog = .system
    ) {
        self.isSceneActive = isSceneActive
        self.makeIdentifier = makeIdentifier
        self.register = register
        self.blocking = blocking
        self.offMainThread = offMainThread
        self.log = log
    }

    public var hasActiveTask: Bool { activeIdentifier != nil }

    /// The task with `identifier` is the one this app submitted last and that has not ended.
    public func isCurrent(_ identifier: String) -> Bool { activeIdentifier == identifier }

    /// Submits one request when a scene is active, no task of this app runs and the backup owes work.
    public func submitIfAllowed(owesWork: Bool) {
        guard isSceneActive(), activeIdentifier == nil, owesWork else { return }
        // A new identifier for each request: the system ends the app at a second registration of one identifier.
        let identifier = makeIdentifier()
        guard register(identifier) else {
            log.notice(.photoBackup, "continued.registrationFailed")
            return
        }
        // The launch can come before the scheduler's answer, so the task counts as active from here.
        activeIdentifier = identifier
        submitter.submit(
            blocking: { [blocking] in try blocking(identifier) }, offMainThread: offMainThread(identifier),
            completion: { [weak self] error in
                self?.log.requestSubmitted(
                    .continuedBackup, earliestBegin: nil, errorCode: error.map { ($0 as NSError).code })
                if error != nil { self?.taskEnded(identifier) }
            })
    }

    /// The task with `identifier` ended, or its request was refused.
    public func taskEnded(_ identifier: String) {
        if activeIdentifier == identifier { activeIdentifier = nil }
    }
}
