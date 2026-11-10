import Foundation
import PhotosCore

/// The one submit point of the continued backup task (#1108). Only the person's "Continue" in the continued-backup
/// prompt calls it, and it submits only from the foreground, while the backup owes work and no task of this app runs.
/// The platform adapter supplies the scheduler: `register` registers the launch handler of one identifier, and `submit`
/// sends its request and reports the scheduler's answer.
@MainActor
public final class PhotoLibraryContinuedBackupSubmission {
    private let isSceneActive: @MainActor () -> Bool
    private let makeIdentifier: @MainActor () -> String
    private let register: @MainActor (String) -> Bool
    private let submit: @MainActor (String, @escaping @MainActor ((any Error)?) -> Void) -> Void
    private let log: BackgroundWorkLog
    /// The identifier of the task that is submitted or runs. One task at a time.
    private var activeIdentifier: String?

    public init(
        isSceneActive: @escaping @MainActor () -> Bool,
        makeIdentifier: @escaping @MainActor () -> String,
        register: @escaping @MainActor (String) -> Bool,
        submit: @escaping @MainActor (String, @escaping @MainActor ((any Error)?) -> Void) -> Void,
        log: BackgroundWorkLog = .system
    ) {
        self.isSceneActive = isSceneActive
        self.makeIdentifier = makeIdentifier
        self.register = register
        self.submit = submit
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
        submit(identifier) { [weak self] error in
            self?.log.requestSubmitted(
                .continuedBackup, earliestBegin: nil, errorCode: error.map { ($0 as NSError).code })
            if error != nil { self?.taskEnded(identifier) }
        }
    }

    /// The task with `identifier` ended, or its request was refused.
    public func taskEnded(_ identifier: String) {
        if activeIdentifier == identifier { activeIdentifier = nil }
    }
}
