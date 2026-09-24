import PhotosCore
import ProtonDriveBackend

/// Main-actor owner of the one ``LibrarySourceAnalysisRuntime`` that a platform library host runs.
///
/// Both app hosts share its ordering contract:
/// - Every primary inventory gets a new generation. An admission result counts only while the same runtime and
///   generation are still current, so a delayed result can never fail a newer inventory.
/// - Lifecycle work (the Mac startup or an iOS activation change) is joined before the runtime shuts down.
/// - Every shutdown waits for the previous shutdown, so two runtimes never own the same account stores at once.
@MainActor
public final class LibrarySourceAnalysisSession {
    public private(set) var runtime: LibrarySourceAnalysisRuntime?
    /// The latest shutdown. A replacement runtime starts only after it completes.
    public private(set) var shutdownTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var primaryInventoryGeneration: UInt64 = 0

    public init() {}

    /// Installs a runtime for the current account. The host has stopped any previous runtime first.
    public func install(_ runtime: LibrarySourceAnalysisRuntime) {
        self.runtime = runtime
    }

    /// Starts the installed runtime with its first primary inventory on a tracked lifecycle task, after the previous
    /// shutdown completes. `onFailure` runs when that inventory is rejected or unavailable while still current.
    public func startPrimaryInventory(
        _ items: [PhotoItem],
        authority: SourceInventoryAuthority,
        onFailure: @escaping @MainActor () -> Void
    ) {
        guard let runtime else { return }
        let generation = nextPrimaryInventoryGeneration()
        let previousShutdown = shutdownTask
        lifecycleTask = Task { [weak self] in
            await previousShutdown?.value
            let admission = await runtime.start(primaryItems: items, authority: authority, generation: generation)
            self?.reportAdmission(admission, runtime: runtime, generation: generation, onFailure: onFailure)
        }
    }

    /// Starts the installed runtime with `items` after the previous shutdown completes and returns the admission.
    /// Returns `.unavailable` when the caller was cancelled or the runtime was stopped while it waited.
    public func synchronizePrimaryInventory(
        _ items: [PhotoItem],
        authority: SourceInventoryAuthority
    ) async -> PrimaryInventoryAdmission {
        guard let runtime else { return .unavailable }
        let generation = nextPrimaryInventoryGeneration()
        let previousShutdown = shutdownTask
        await previousShutdown?.value
        guard !Task.isCancelled, self.runtime === runtime else { return .unavailable }
        return await runtime.start(primaryItems: items, authority: authority, generation: generation)
    }

    /// Replaces the primary inventory of the installed runtime. `onFailure` runs when the replacement is rejected or
    /// unavailable while the same runtime and generation are still current.
    public func replacePrimaryInventory(
        _ items: [PhotoItem],
        authority: SourceInventoryAuthority,
        onFailure: @escaping @MainActor () -> Void
    ) {
        guard let runtime else { return }
        let generation = nextPrimaryInventoryGeneration()
        Task { [weak self] in
            let admission = await runtime.replacePrimaryInventory(items, authority: authority, generation: generation)
            self?.reportAdmission(admission, runtime: runtime, generation: generation, onFailure: onFailure)
        }
    }

    /// Runs `operation` on the installed runtime after the previous lifecycle work. A stop cancels and joins it.
    public func enqueueLifecycle(_ operation: @escaping @Sendable (LibrarySourceAnalysisRuntime) async -> Void) {
        guard let runtime else { return }
        let previous = lifecycleTask
        lifecycleTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation(runtime)
        }
    }

    /// Detaches the runtime and returns the shutdown that joins its lifecycle work. When nothing is running, returns
    /// the latest shutdown so a caller can still wait for store ownership to end.
    @discardableResult
    public func stop() -> Task<Void, Never>? {
        let runtime = self.runtime
        self.runtime = nil
        let lifecycle = lifecycleTask
        lifecycleTask = nil
        guard runtime != nil || lifecycle != nil else { return shutdownTask }
        lifecycle?.cancel()
        let previous = shutdownTask
        let task = Task {
            await previous?.value
            await lifecycle?.value
            await runtime?.shutdown()
        }
        shutdownTask = task
        return task
    }

    private func nextPrimaryInventoryGeneration() -> UInt64 {
        primaryInventoryGeneration &+= 1
        return primaryInventoryGeneration
    }

    private func reportAdmission(
        _ admission: PrimaryInventoryAdmission,
        runtime: LibrarySourceAnalysisRuntime,
        generation: UInt64,
        onFailure: @MainActor () -> Void
    ) {
        guard self.runtime === runtime, primaryInventoryGeneration == generation else { return }
        if admission == .rejected || admission == .unavailable { onFailure() }
    }
}
