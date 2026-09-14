import Foundation
import MLSearchCore
import MediaFeedCore
import PhotosCore

/// Owns one account's Smart Search stack on Apple platforms: the lifecycle actor, its controller, the
/// background-execution attachment, the memory-pressure registration and the ordered shutdown chain.
/// Platform models keep only their intentional differences at the call site.
@MainActor
@Observable
public final class AppleSmartSearchSession {
    public private(set) var controller: MLSmartSearchController?
    /// Shared with the library source analysis runtime, which publishes the analysable asset scope.
    @ObservationIgnored public let assets = MLAssetUniverse()
    @ObservationIgnored private let backgroundHost: any MLSmartSearchBackgroundHost
    @ObservationIgnored private var memoryRegistration: MemoryPressureRegistration?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?

    public init(backgroundHost: any MLSmartSearchBackgroundHost) {
        self.backgroundHost = backgroundHost
    }

    /// Stops any existing lifecycle (ordered shutdown chain) and builds the account-scoped lifecycle.
    /// Leaves `controller` nil when Smart Search is unavailable on this device.
    public func configure(
        accountDirectory: URL,
        accountUID: String,
        keyPassword: String,
        feed: ThumbnailFeedCore,
        databasePolicy: LibraryDatabasePolicy
    ) {
        if controller != nil { _ = stop() }
        guard AppleSmartSearchBootstrap.featureAvailability() == .available else { return }
        #if DEBUG
            let allowsDeveloperModels = true
        #else
            let allowsDeveloperModels = false
        #endif
        #if DEBUG
            let catalogEndpoint = AppleSmartSearchCatalogEndpoint.debugEndpoint(
                environment: ProcessInfo.processInfo.environment
            )
        #else
            let catalogEndpoint = AppleSmartSearchCatalogEndpoint.production
        #endif
        let lifecycle = AppleSmartSearchBootstrap.makeLifecycle(
            accountDirectory: accountDirectory,
            accountUID: accountUID,
            keyPassword: keyPassword,
            feed: feed,
            assetsProvider: { [assets] in assets.snapshot() },
            allowsDeveloperModels: allowsDeveloperModels,
            databasePolicy: databasePolicy,
            catalogEndpoint: catalogEndpoint
        )
        controller = MLSmartSearchController(lifecycle: lifecycle)
        backgroundHost.configure(lifecycle: lifecycle)
        // Under memory pressure the search stack drops cached vector blocks and unloads the
        // CoreML model; both rebuild on demand.
        memoryRegistration?.end()
        memoryRegistration = MemoryPressureGovernor.shared.register { tier in
            guard tier.requiresImmediatePurge else { return }
            Task { await lifecycle.releaseMemory() }
        }
    }

    /// Stops Smart Search and returns the ordered-shutdown task. Consecutive stops chain, so a later awaiter
    /// always sees every previous lifecycle fully torn down.
    @discardableResult
    public func stop() -> Task<Void, Never>? {
        let lifecycle = controller?.lifecycleActor
        if let lifecycle { backgroundHost.detach(lifecycle: lifecycle) }
        controller = nil
        assets.beginHydration()
        memoryRegistration?.end()
        memoryRegistration = nil
        guard let lifecycle else { return shutdownTask }
        let previous = shutdownTask
        let task = Task {
            await previous?.value
            await lifecycle.shutdown()
        }
        shutdownTask = task
        return task
    }
}
