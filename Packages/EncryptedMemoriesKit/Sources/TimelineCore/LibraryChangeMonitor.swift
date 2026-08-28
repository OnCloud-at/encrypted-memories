import Foundation
import PhotosCore

/// Shared foreground polling policy for remote library mutations. The probe is deliberately cheap
/// (an opaque server event token); a full timeline refresh runs only after that token changes.
public struct LibraryChangePollingPolicy: Sendable, Equatable {
    public let interval: Duration
    public let refreshRetryInterval: Duration
    public let failureInterval: Duration

    public init(interval: Duration, refreshRetryInterval: Duration? = nil, failureInterval: Duration) {
        self.interval = interval
        self.refreshRetryInterval = refreshRetryInterval ?? interval
        self.failureInterval = failureInterval
    }

    /// Five seconds keeps a second foreground device visibly current without repeatedly enumerating
    /// a large library. Failures back off so an offline device does not hot-loop the API.
    public static let foreground = LibraryChangePollingPolicy(
        interval: .seconds(5),
        refreshRetryInterval: .seconds(5),
        failureInterval: .seconds(30)
    )
}

/// Result of the authoritative refresh requested after a change-token transition. A terminal result retires
/// the monitor before it invokes the host callback, including when scope loss appears during the full load.
public enum LibraryChangeRefreshOutcome: Sendable, Equatable {
    case refreshed
    case retry
    case terminal
}

/// One platform-neutral monitor shared by macOS, iOS and iPadOS. Hosts only express lifecycle by
/// starting/stopping it; token comparison, cadence, failure backoff and refresh coalescing live here.
public actor LibraryChangeMonitor {
    private struct StartRequest: Sendable {
        let provider: any LibraryChangeTokenProvider
        let policy: LibraryChangePollingPolicy
        let resetBaseline: Bool
        let initialToken: String?
        let onChange: @Sendable () async -> LibraryChangeRefreshOutcome
        let onTerminal: @Sendable (any LibraryChangeTerminalError) async -> Void
    }

    private enum DesiredLifecycle: Sendable {
        case stopped(resetBaseline: Bool)
        case start(StartRequest)
        case active
    }

    private var task: Task<Void, Never>?
    private var activeTaskID: UInt64?
    private var retiringTaskID: UInt64?
    private var nextTaskID: UInt64 = 0
    private var desiredLifecycle: DesiredLifecycle = .stopped(resetBaseline: false)
    private var lastToken: String?

    public init() {}

    public func start(
        provider: any LibraryChangeTokenProvider,
        policy: LibraryChangePollingPolicy = .foreground,
        initialToken: String? = nil,
        onTerminal: @Sendable @escaping (any LibraryChangeTerminalError) async -> Void = { _ in },
        onChange: @Sendable @escaping () async -> LibraryChangeRefreshOutcome
    ) {
        // Repeated starts remain idempotent while a monitor is active. A start that arrives while stop,
        // restart or reset is joining the old task becomes the desired next state instead of being dropped.
        guard task == nil || retiringTaskID != nil else { return }
        desiredLifecycle = .start(
            StartRequest(
                provider: provider,
                policy: policy,
                resetBaseline: false,
                initialToken: initialToken,
                onChange: onChange,
                onTerminal: onTerminal
            ))
        applyDesiredLifecycleIfPossible()
    }

    private func launch(_ request: StartRequest) {
        if request.resetBaseline { lastToken = nil }
        // A startup seed fills only an unknown baseline. Reappearing views must not overwrite a newer token the
        // same monitor already observed while the app was running.
        if lastToken == nil, let initialToken = request.initialToken { lastToken = initialToken }
        let delayFirstProbe = lastToken != nil
        nextTaskID &+= 1
        let taskID = nextTaskID
        activeTaskID = taskID
        desiredLifecycle = .active
        task = Task {
            // A validated/full load just observed this revision. Polling it again immediately adds an API call
            // to the launch critical path without increasing correctness; the seeded baseline still detects
            // every later mutation on the normal foreground cadence.
            if delayFirstProbe {
                do {
                    try await Task.sleep(for: request.policy.interval)
                } catch {
                    return
                }
            }
            while !Task.isCancelled {
                do {
                    let token = try await request.provider.libraryChangeToken()
                    try Task.checkCancellation()
                    if let lastToken, token != lastToken {
                        switch await request.onChange() {
                        case .refreshed:
                            break
                        case .retry:
                            // A successful token probe with an inventory that has not converged is not a
                            // transport failure. Keep the old token and retry at the normal foreground cadence.
                            try? await Task.sleep(for: request.policy.refreshRetryInterval)
                            continue
                        case .terminal:
                            await handleTerminal(
                                taskID: taskID,
                                error: LibraryChangeRefreshTerminalError(),
                                onTerminal: request.onTerminal
                            )
                            return
                        }
                    }
                    try Task.checkCancellation()
                    lastToken = token
                    try await Task.sleep(for: request.policy.interval)
                } catch is CancellationError {
                    break
                } catch let error as any LibraryChangeTerminalError {
                    await handleTerminal(
                        taskID: taskID,
                        error: error,
                        onTerminal: request.onTerminal
                    )
                    return
                } catch {
                    try? await Task.sleep(for: request.policy.failureInterval)
                }
            }
        }
    }

    public func stop() async {
        desiredLifecycle = .stopped(resetBaseline: false)
        await retireCurrentTask()
    }

    public func restart(
        provider: any LibraryChangeTokenProvider,
        policy: LibraryChangePollingPolicy = .foreground,
        resetBaseline: Bool = false,
        initialToken: String? = nil,
        onTerminal: @Sendable @escaping (any LibraryChangeTerminalError) async -> Void = { _ in },
        onChange: @Sendable @escaping () async -> LibraryChangeRefreshOutcome
    ) async {
        desiredLifecycle = .start(
            StartRequest(
                provider: provider,
                policy: policy,
                resetBaseline: resetBaseline,
                initialToken: initialToken,
                onChange: onChange,
                onTerminal: onTerminal
            ))
        await retireCurrentTask()
    }

    public func reset() async {
        desiredLifecycle = .stopped(resetBaseline: true)
        await retireCurrentTask()
    }

    /// Retires a terminal task before notifying its host. The callback can therefore reset or restart this
    /// monitor without joining the task that is currently invoking it. Scope loss invalidates the baseline.
    private func handleTerminal(
        taskID: UInt64,
        error: any LibraryChangeTerminalError,
        onTerminal: @Sendable (any LibraryChangeTerminalError) async -> Void
    ) async {
        guard activeTaskID == taskID, retiringTaskID == nil else { return }
        task = nil
        activeTaskID = nil
        lastToken = nil
        desiredLifecycle = .stopped(resetBaseline: false)
        await onTerminal(error)
    }

    private func retireCurrentTask() async {
        let retiringTask = task
        guard let retiringTask, let taskID = activeTaskID else {
            task = nil
            activeTaskID = nil
            retiringTaskID = nil
            applyDesiredLifecycleIfPossible()
            return
        }

        retiringTaskID = taskID
        retiringTask.cancel()
        await retiringTask.value

        // Several lifecycle callers can join the same task. Only the first completion for that exact task
        // applies the latest desired state; older completions must not clear a replacement task.
        guard retiringTaskID == taskID, activeTaskID == taskID else { return }
        task = nil
        activeTaskID = nil
        retiringTaskID = nil
        applyDesiredLifecycleIfPossible()
    }

    private func applyDesiredLifecycleIfPossible() {
        guard task == nil, retiringTaskID == nil else { return }
        switch desiredLifecycle {
        case .stopped(let resetBaseline):
            if resetBaseline { lastToken = nil }
            desiredLifecycle = .stopped(resetBaseline: false)
        case .start(let request):
            launch(request)
        case .active:
            break
        }
    }
}

private struct LibraryChangeRefreshTerminalError: LibraryChangeTerminalError {}
