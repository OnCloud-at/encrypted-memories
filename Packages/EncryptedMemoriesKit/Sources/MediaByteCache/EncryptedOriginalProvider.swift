import Foundation
import PhotosCore

/// Cache policy for ``EncryptedOriginalProvider``. Separated from the cache instance so the same
/// encrypted store can back both a *persisting* consumer (the fullscreen viewer, which should seed
/// the cache the first time an original is decrypted) and a *read-only* consumer (export/share, which
/// reuses whatever the viewer already cached but must not itself grow the cache - mirroring macOS
/// `MainView.fetchOriginal`, which only ever READS the offline cache).
public struct OriginalsCachePolicy: Sendable, Equatable {
    /// Whether a network download (cache miss) is sealed into the encrypted cache afterwards.
    public var storeOnMiss: Bool
    /// LRU byte cap enforced right after a store (nil = don't enforce here; the owner may cap elsewhere).
    public var capBytes: Int64?

    public init(storeOnMiss: Bool, capBytes: Int64? = nil) {
        self.storeOnMiss = storeOnMiss
        self.capBytes = capBytes
    }

    /// Viewer policy: seed the cache on first decrypt, then keep it under `capBytes`.
    public static func persisting(capBytes: Int64?) -> OriginalsCachePolicy {
        OriginalsCachePolicy(storeOnMiss: true, capBytes: capBytes)
    }

    /// Export/share policy: reuse the cache if warm, but never grow it.
    public static let readOnly = OriginalsCachePolicy(storeOnMiss: false, capBytes: nil)
}

public enum EncryptedOriginalProviderError: Error, Equatable, Sendable {
    case sessionInvalidated
}

/// Shared cache-first access to decrypted original bytes for viewer and export flows.
///
/// Contract:
/// - **Cache hit** returns the cached plaintext and bumps its LRU marker without touching
///   ``FullMediaProvider/originalData(for:onProgress:)`` (no redundant network/decrypt).
/// - **Cache miss** downloads via the provider (forwarding real byte progress), then, when the
///   policy persists - seals the bytes into the encrypted cache and enforces the byte cap.
/// - All disk read/decrypt/seal work runs off the calling actor (`Task.detached`), so a main-actor
///   caller never blocks on AES-GCM or file I/O.
/// - Returns raw `Data`; decoding to a platform image stays in each platform's UI layer, so this type
///   is platform-UI-free and lives next to the cache it drives.
public struct EncryptedOriginalProvider: Sendable {
    private let media: any FullMediaProvider
    private let cache: ThumbnailCache?
    private let policy: OriginalsCachePolicy
    /// Stable owner lease. A provider must not continue an account-A operation after its cache is configured
    /// for account B, even when the backend ignores task cancellation.
    private let sessionLease: CacheWriterGeneration.SessionToken?

    /// - Parameters:
    ///   - media: the backend original-bytes source (never re-implement block download/decrypt).
    ///   - cache: the encrypted originals cache, or `nil` to disable caching entirely (always downloads).
    ///   - policy: whether a miss is persisted and the LRU cap to enforce afterwards.
    public init(media: any FullMediaProvider, cache: ThumbnailCache?, policy: OriginalsCachePolicy) {
        self.media = media
        self.cache = cache
        self.policy = policy
        self.sessionLease = cache?.captureSessionLease()
    }

    private func leaseIsCurrent() -> Bool {
        guard let cache, let sessionLease else { return true }
        return cache.isCurrentSessionLease(sessionLease)
    }

    /// Decrypted original bytes, cache-first. See the type contract above.
    public func originalData(
        for uid: PhotoUID,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Data {
        guard leaseIsCurrent() else { throw EncryptedOriginalProviderError.sessionInvalidated }
        if let cache {
            let readGeneration = cache.captureWriterGeneration()
            // Encrypted read + AES-GCM decrypt off the caller's actor; bump LRU on a hit.
            let cached = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard cache.isCurrentWriterGeneration(readGeneration) else { return nil }
                guard let data = cache.diskData(for: uid) else { return nil }
                guard cache.isCurrentWriterGeneration(readGeneration) else { return nil }
                _ = cache.touch(uid, ifCurrent: readGeneration)
                return data
            }.value
            if let cached {
                guard leaseIsCurrent(), cache.isCurrentWriterGeneration(readGeneration) else {
                    throw EncryptedOriginalProviderError.sessionInvalidated
                }
                onProgress(1)  // a warm hit "completes" immediately for progress UIs
                return cached
            }
        }

        // Capture the writer generation before entering the non-cooperative backend. A clear or sign-out
        // during that await must reject the late cache write. The separate owner lease below distinguishes
        // an ordinary same-account clear from an account/session replacement.
        let writerGeneration: CacheWriterGeneration.Token?
        if let cache, policy.storeOnMiss {
            writerGeneration = cache.captureWriterGeneration()
        } else {
            writerGeneration = nil
        }
        guard leaseIsCurrent() else { throw EncryptedOriginalProviderError.sessionInvalidated }

        // Cache miss: fetch the original and report byte progress.
        let data = try await media.originalData(for: uid, onProgress: onProgress)
        guard leaseIsCurrent() else { throw EncryptedOriginalProviderError.sessionInvalidated }

        if let cache, policy.storeOnMiss, let writerGeneration {
            let cap = policy.capBytes
            // Seal + write + LRU-cap off the caller's actor.
            _ = await Task.detached(priority: .utility) {
                let result = cache.storeToDisk(data, for: uid, ifCurrent: writerGeneration)
                guard result != .stale else { return result }
                if let cap { _ = cache.enforceByteCap(cap, ifCurrent: writerGeneration) }
                return result
            }.value
            guard leaseIsCurrent() else {
                throw EncryptedOriginalProviderError.sessionInvalidated
            }
        }
        guard leaseIsCurrent() else { throw EncryptedOriginalProviderError.sessionInvalidated }
        return data
    }
}
