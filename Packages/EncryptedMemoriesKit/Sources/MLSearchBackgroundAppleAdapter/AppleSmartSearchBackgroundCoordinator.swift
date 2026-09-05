import Foundation
import MLSearchCore
import PhotosCore
import os

#if os(iOS)
    import BackgroundTasks
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// Apple execution opportunities for the account's existing indexer. No second session, index,
/// download queue or credential store is created by a background launch.
@MainActor
public final class AppleSmartSearchBackgroundCoordinator {
    public static let shared = AppleSmartSearchBackgroundCoordinator()
    public static let processingTaskIdentifier = "at.oncloud.encryptedmemories.smart-search.processing"

    private let reference = WeakAsyncReference<MLSmartSearchLifecycle>()
    private let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "SmartSearchBackground")
    private var observationTask: Task<Void, Never>?
    private var isEnabled = false
    private var schedulingStopped = false

    #if os(iOS)
        private var didRegister = false
        private var isForeground = UIApplication.shared.applicationState != .background
        private var windows: Set<UUID> = []
        private var processing: [UUID: Task<Void, Never>] = [:]
        private var transitionTask: Task<Void, Never>?
    #elseif os(macOS)
        private var activityScheduler: NSBackgroundActivityScheduler?
        private var activityGeneration = UUID()
    #endif

    private init() {}

    /// Must be called from app initialization, before the system delivers launch tasks.
    public func register() {
        #if os(iOS)
            guard !didRegister else { return }
            didRegister = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.processingTaskIdentifier, using: nil
            ) { task in
                guard let task = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor in Self.shared.handle(task) }
            }
            if !didRegister { logger.error("Smart Search background registration failed") }
        #endif
    }

    public func configure(lifecycle: MLSmartSearchLifecycle) {
        if let previous = reference.value, previous !== lifecycle { detach(lifecycle: previous) }
        schedulingStopped = false
        reference.value = lifecycle
        observationTask?.cancel()
        observationTask = Task { [weak self, weak lifecycle] in
            guard let lifecycle else { return }
            let snapshots = await lifecycle.snapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled, let self, self.reference.value === lifecycle else { return }
                if self.isEnabled != snapshot.isEnabled {
                    self.isEnabled = snapshot.isEnabled
                    if snapshot.isEnabled { self.schedule() } else { self.cancelScheduling() }
                }
            }
        }
        #if os(iOS)
            isForeground = UIApplication.shared.applicationState != .background
            _ = reconcileExecution()
        #endif
    }

    public func detach(lifecycle: MLSmartSearchLifecycle) {
        guard reference.value === lifecycle else { return }
        stop()
    }

    /// Also valid before account restoration: a pending local reset must revoke queued OS work.
    public func stop() {
        schedulingStopped = true
        reference.value = nil
        observationTask?.cancel()
        observationTask = nil
        isEnabled = false
        cancelScheduling()
        #if os(iOS)
            for task in processing.values { task.cancel() }
            windows.removeAll()
        #endif
    }

    public func applicationStateChanged(isForeground: Bool) {
        #if os(iOS)
            self.isForeground = isForeground
            if isForeground {
                _ = reconcileExecution()
            } else {
                if isEnabled { schedule() }
                // A finite UIKit grace period lets the current quantum drain when there is no
                // BGProcessing window. It is not permission to start another indexing pass.
                let grace = IndexingDrainGrace()
                grace.begin()
                let transition = reconcileExecution()
                Task {
                    await transition.value
                    grace.end()
                }
            }
        #endif
    }

    private func cancelScheduling() {
        #if os(iOS)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskIdentifier)
        #elseif os(macOS)
            activityScheduler?.invalidate()
            activityScheduler = nil
            activityGeneration = UUID()
        #endif
    }

    private func schedule() {
        guard !schedulingStopped else { return }
        #if os(iOS)
            let request = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = false
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            do { try BGTaskScheduler.shared.submit(request) } catch {
                logger.error(
                    "Smart Search background submission failed: \(error.localizedDescription, privacy: .public)")
            }
        #elseif os(macOS)
            guard activityScheduler == nil else { return }
            let scheduler = NSBackgroundActivityScheduler(identifier: Self.processingTaskIdentifier)
            scheduler.interval = 15 * 60
            scheduler.tolerance = 5 * 60
            scheduler.repeats = true
            scheduler.qualityOfService = .background
            let generation = UUID()
            activityGeneration = generation
            scheduler.schedule { completion in
                Task { @MainActor in
                    guard Self.shared.activityGeneration == generation else {
                        completion(.finished)
                        return
                    }
                    guard let scheduler = Self.shared.activityScheduler, !scheduler.shouldDefer else {
                        completion(.deferred)
                        return
                    }
                    guard let lifecycle = Self.shared.reference.value else {
                        completion(.finished)
                        return
                    }
                    let activity = ProcessInfo.processInfo.beginActivity(
                        options: .background, reason: "Smart Search indexing")
                    _ = await lifecycle.performBackgroundCatchUp()
                    ProcessInfo.processInfo.endActivity(activity)
                    completion(.finished)
                }
            }
            activityScheduler = scheduler
        #endif
    }

    #if os(iOS)
        /// Serialize lifecycle transitions. Each queued transition reads the latest opportunity,
        /// so an expired background task cannot disable a newly foregrounded app.
        private func reconcileExecution() -> Task<Void, Never> {
            let previous = transitionTask
            let lifecycle = reference.value
            let task = Task { [weak self] in
                await previous?.value
                guard let self, let lifecycle, self.reference.value === lifecycle else { return }
                await lifecycle.setIndexingExecutionAllowed(self.isForeground || !self.windows.isEmpty)
            }
            transitionTask = task
            return task
        }

        private func handle(_ task: BGProcessingTask) {
            guard !schedulingStopped else {
                task.setTaskCompleted(success: false)
                return
            }
            // A cold, locked launch may not restore when-unlocked credentials. Preserve the
            // security policy and retry later; never start a second login/session bootstrap.
            schedule()
            let id = UUID()
            let operation = Task { [weak self] in
                defer { task.expirationHandler = nil }
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                guard let lifecycle = await self.reference.whenReady(timeout: .seconds(30)),
                    !Task.isCancelled, self.reference.value === lifecycle
                else {
                    self.processing.removeValue(forKey: id)
                    task.setTaskCompleted(success: false)
                    return
                }
                self.windows.insert(id)
                await self.reconcileExecution().value
                // The reference can be published before the UI's startup task runs. Restore
                // this same idempotent lifecycle before interpreting its default disabled state.
                await lifecycle.start()
                let result = await lifecycle.performBackgroundCatchUp()
                self.windows.remove(id)
                await self.reconcileExecution().value
                if !self.isForeground { await lifecycle.releaseMemory() }
                self.processing.removeValue(forKey: id)
                task.setTaskCompleted(success: !Task.isCancelled && result != .cancelled)
            }
            processing[id] = operation
            task.expirationHandler = { operation.cancel() }
        }
    #endif
}

#if os(iOS)
    @MainActor
    private final class IndexingDrainGrace {
        private var identifier = UIBackgroundTaskIdentifier.invalid

        func begin() {
            identifier = UIApplication.shared.beginBackgroundTask(withName: "SmartSearchDrain") { [weak self] in
                self?.end()
            }
        }

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
#endif
