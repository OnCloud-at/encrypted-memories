import AppKit
import Foundation
import LibraryRuntimeAppleAdapter
import MediaCacheAppKitAdapter
import PhotoViewerFeature
import PhotosCore

/// Connects macOS cache owners to the shared memory-pressure policy.
/// Elevated pressure reduces future budgets. Serious pressure also purges disposable data.
@MainActor
final class AppMemoryPressureCoordinator {
    static let shared = AppMemoryPressureCoordinator()

    private var staticRespondersRegistered = false
    private var feedRegistration: (id: ObjectIdentifier, token: MemoryPressureRegistration)?

    private init() {}

    /// Installs the shared signal adapter and registers app-lifetime cache owners.
    func install() {
        AppleLibraryRuntimeAdapter.shared.install()
        registerStaticResponders()
    }

    /// Replaces the thumbnail-feed registration when SwiftUI creates a new feed instance.
    func attachFeed(_ feed: ThumbnailFeed) {
        let id = ObjectIdentifier(feed)
        if feedRegistration?.id == id { return }
        feedRegistration?.token.end()
        let token = MemoryPressureGovernor.shared.register { [weak feed] tier in
            feed?.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
        }
        feedRegistration = (id, token)
    }

    private func registerStaticResponders() {
        guard !staticRespondersRegistered else { return }
        staticRespondersRegistered = true
        let governor = MemoryPressureGovernor.shared
        // Viewer full-resolution cache (static, shared across viewer instances) - the single most
        // jetsam-prone RAM consumer.
        governor.register { tier in
            PhotoViewerModel.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
        }
        // Encrypted thumbnail byte cache (in-process plaintext RAM tier) - app-lifetime singleton.
        let byteCache = OfflineLibraryManager.shared.cache
        governor.register { tier in
            byteCache.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
        }
    }
}
