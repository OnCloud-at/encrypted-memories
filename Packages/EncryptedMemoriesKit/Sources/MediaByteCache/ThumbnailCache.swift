import CryptoKit
import Foundation
import PhotosCore

public struct ThumbnailCacheConfiguration: Sendable, Equatable {
    public let dataMemoryBudgetBytes: Int
    /// Optional encrypted-disk byte budget. `nil` keeps whole-library thumbnails unbounded, applies the
    /// shared preview default, and leaves other derivatives unbounded unless a policy supplies a value.
    public let diskByteBudgetBytes: Int64?

    /// Shared Core preview default. The thumbnail feed promises complete persisted coverage, so an automatic
    /// thumbnail cap would evict older blobs while its coverage checkpoint still reports them as present.
    public static let defaultPreviewDiskBudgetBytes: Int64 = 2_147_483_648

    public init(
        dataMemoryBudgetBytes: Int = 128 * 1024 * 1024,
        diskByteBudgetBytes: Int64? = nil
    ) {
        self.dataMemoryBudgetBytes = max(1, dataMemoryBudgetBytes)
        self.diskByteBudgetBytes = diskByteBudgetBytes.map { max(0, $0) }
    }
}

/// Result of a generation-bound encrypted cache write.
public enum ThumbnailCacheStoreResult: Sendable, Equatable {
    case stored
    case stale
    case ioFailure
}

/// Two-tier thumbnail cache: in-memory (NSCache) backed by an encrypted on-disk store. Keeps decoded
/// thumbnails resident for smooth scrolling and survives relaunch.
///
/// Security: on-disk blobs are AES-GCM sealed (see `SecureBlobCipher`) with a per-account 256-bit key.
/// Production supplies that key from the already-unlocked Proton session (`configure(accountUID:key:)`) so
/// startup does not need a second cache-key Keychain read. Plaintext thumbnail and preview bytes are never
/// written to disk; the in-memory tier holds plaintext for the running process only. The cache is usable
/// before sign-in via a process-ephemeral key (nothing readable persists). Reads transparently decrypt;
/// a failed authentication tag is a cache miss and
/// the corrupt blob is deleted, while a missing key (locked cache) is a plain miss that keeps the blob - never
/// a crash.
public actor ThumbnailCache {
    private nonisolated(unsafe) let memory = NSCache<NSString, NSData>()  // NSCache is thread-safe
    /// Encrypted blob directory (`<namespace>.enc`).
    private nonisolated let directory: URL
    private nonisolated let coverageCheckpointDir: URL
    private nonisolated let namespace: String
    private nonisolated let derivative: String
    private nonisolated let crypto: CryptoBox
    /// Fence for loaders and detached writers that can outlive a destructive clear or session change.
    private nonisolated let writerGeneration = CacheWriterGeneration()
    private nonisolated let retentionScopeFence =
        DerivedDataScopeRevisionFence<ThumbnailRetentionDerivedDataScopeKind>()
    private nonisolated let retentionAuthorization =
        DerivedDataResourceAuthorization<ThumbnailRetentionDerivedDataScopeKind>()
    /// Filenames proven decryptable this session (so `hasUsableDiskData` is O(1) after the first probe).
    private nonisolated let validated = ValidatedPresence()
    /// Nominal RAM-tier byte budget, retained so a memory-pressure scale can be restored to full.
    private nonisolated let dataMemoryBudgetBytes: Int
    /// Shared derivative cap. Directory scans run through `automaticDiskCapScheduler`, never on the cache caller.
    private nonisolated let automaticDiskCapBytes: Int64?
    private nonisolated let automaticDiskCapScheduler: ThumbnailCacheDiskCapScheduler?

    public init(
        namespace: String = "thumbnails",
        derivative: String? = nil,
        rootDirectory: URL? = nil
    ) {
        self.init(
            namespace: namespace,
            derivative: derivative,
            configuration: ThumbnailCacheConfiguration(),
            rootDirectory: rootDirectory
        )
    }

    public init(
        namespace: String = "thumbnails",
        derivative: String? = nil,
        configuration: ThumbnailCacheConfiguration = ThumbnailCacheConfiguration(),
        rootDirectory: URL? = nil
    ) {
        let root = rootDirectory ?? Self.defaultRootDirectory()
        let resolvedDerivative = derivative ?? Self.defaultDerivative(for: namespace)
        self.namespace = namespace
        self.derivative = resolvedDerivative
        self.directory = root.appendingPathComponent("\(namespace).enc", isDirectory: true)
        self.coverageCheckpointDir = root.appendingPathComponent("\(namespace).coverage", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Secure by default: until account configuration installs the durable per-account key, seal with a
        // process-ephemeral key so nothing readable persists across launches, while in-process round-trips
        // still work (e.g. tests).
        self.crypto = CryptoBox(
            cipher: SecureBlobCipher(
                key: SymmetricKey(size: .bits256),
                namespace: namespace,
                accountUID: CryptoBox.ephemeralAccount,
                derivative: resolvedDerivative),
            account: CryptoBox.ephemeralAccount
        )
        self.dataMemoryBudgetBytes = configuration.dataMemoryBudgetBytes
        let automaticDiskCapBytes =
            configuration.diskByteBudgetBytes
            ?? Self.defaultDiskByteBudget(for: resolvedDerivative)
        self.automaticDiskCapBytes = automaticDiskCapBytes
        self.automaticDiskCapScheduler = automaticDiskCapBytes.map { _ in ThumbnailCacheDiskCapScheduler() }
        memory.totalCostLimit = configuration.dataMemoryBudgetBytes
        if let automaticDiskCapBytes, let automaticDiskCapScheduler {
            automaticDiskCapScheduler.schedule { [weak self] in
                self?.enforceByteCap(automaticDiskCapBytes)
            }
        }
    }

    /// Governor-driven memory-pressure response for the in-process plaintext RAM tier. `scale` lowers
    /// the NSCache cost limit; `purge` drops the tier now. `nonisolated` + thread-safe NSCache, so the
    /// governor never hops the cache actor. The encrypted disk tier is untouched - bytes are re-read
    /// (and decrypted) on demand, never lost.
    public nonisolated func applyMemoryPressure(scale: Double, purge: Bool) {
        let clamped = min(1, max(0, scale))
        memory.totalCostLimit = max(1, Int(Double(dataMemoryBudgetBytes) * clamped))
        if purge { memory.removeAllObjects() }
    }

    public nonisolated static func defaultRootDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EncryptedMemories", isDirectory: true)
    }

    // MARK: - Account configuration

    /// Installs the per-account key derived from the unlocked session. A missing key locks the cache
    /// (reads miss and writes drop) without falling back to plaintext.
    public nonisolated func configure(accountUID: String, key: SymmetricKey?) {
        retentionScopeFence.resetForSessionTransition {
            // A cache instance can be reused across sign-in. Keep captures blocked across the complete crypto
            // transition so an old owner cannot capture a new generation between invalidation and key install.
            writerGeneration.invalidateAndPerform(invalidatesSession: true) {
                retentionAuthorization.reset()
                memory.removeAllObjects()
                validated.clearAll()
                guard let key else {
                    crypto.set(cipher: nil, account: accountUID)
                    return
                }
                crypto.set(
                    cipher: SecureBlobCipher(
                        key: key, namespace: namespace, accountUID: accountUID, derivative: derivative),
                    account: accountUID
                )
            }
        }
    }

    // MARK: - Reads

    /// Cache lookup from decoded memory to encrypted disk. Never triggers a network load.
    public func data(for uid: PhotoUID) -> Data? {
        guard retentionAuthorization.isAllowed(uid) else { return nil }
        let generation = writerGeneration.capture()
        let mk = Self.memKey(uid)
        if let cached = memory.object(forKey: mk) {
            return writerGeneration.performIfCurrent(generation) {
                retentionAuthorization.isAllowed(uid) ? cached as Data : nil
            } ?? nil
        }
        guard let data = diskData(for: uid) else { return nil }
        return writerGeneration.performIfCurrent(generation) {
            guard retentionAuthorization.isAllowed(uid) else { return nil }
            memory.setObject(data as NSData, forKey: mk, cost: data.count)
            return data
        } ?? nil
    }

    /// Cheap on-disk existence check (no read/decrypt) for diagnostics and coverage only. Do not use this to
    /// gate network fetches: with encrypted blobs a corrupt/tampered/wrong-key file can exist yet be
    /// unreadable. Use `hasUsableDiskData(_:)` for any skip-the-network decision.
    public nonisolated func has(_ uid: PhotoUID) -> Bool {
        guard retentionAuthorization.isAllowed(uid) else { return false }
        let generation = writerGeneration.capture()
        let (_, account) = crypto.snapshot()
        let present = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(filename(uid: uid, account: account)).path
        )
        return writerGeneration.isCurrent(generation)
            && retentionAuthorization.isAllowed(uid)
            && present
    }

    /// True only when a decryptable blob is on disk (the safe "skip the network" predicate). On the first
    /// probe per file it actually opens the blob; a corrupt/tampered/wrong-key blob is deleted and returns
    /// false (so it re-fetches). Proven-good files are memoized, so subsequent calls are O(1).
    public nonisolated func hasUsableDiskData(_ uid: PhotoUID) -> Bool {
        isUsableDiskData(uid, trustValidatedPresence: true)
    }

    /// Authenticates the encrypted blob even when this process already memoized its filename as valid.
    /// Startup coverage validation uses this once per queued UID so a replaced or corrupted blob cannot
    /// hide behind a stale in-process proof.
    package nonisolated func hasAuthenticatedDiskData(_ uid: PhotoUID) -> Bool {
        isUsableDiskData(uid, trustValidatedPresence: false)
    }

    private nonisolated func isUsableDiskData(
        _ uid: PhotoUID,
        trustValidatedPresence: Bool
    ) -> Bool {
        guard retentionAuthorization.isAllowed(uid) else { return false }
        let generation = writerGeneration.capture()
        let (cipher, account) = crypto.snapshot()
        guard let cipher else { return false }  // A locked cache has no usable data.
        let name = filename(uid: uid, account: account)
        let url = directory.appendingPathComponent(name)
        if trustValidatedPresence, validated.contains(name, generation: generation) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                validated.remove(name, generation: generation)
                return false
            }
            return writerGeneration.isCurrent(generation)
                && retentionAuthorization.isAllowed(uid)
        }
        guard let blob = try? Data(contentsOf: url) else { return false }
        guard cipher.open(blob, uid: uid) != nil else {
            // Do not let a read from the prior generation delete a replacement written after clear/configure.
            _ = writerGeneration.performIfCurrent(generation) {
                try? FileManager.default.removeItem(at: url)  // Drop unreadable data so the network path refetches it.
                validated.remove(name, generation: generation)
            }
            return false
        }
        let authenticated =
            writerGeneration.performIfCurrent(generation) {
                guard retentionAuthorization.isAllowed(uid) else { return false }
                validated.insert(name, generation: generation)
                return true
            } ?? false
        return authenticated && retentionAuthorization.isAllowed(uid)
    }

    /// Direct disk read + decrypt (no in-memory layer). Returns plaintext bytes, or `nil` on a miss, a
    /// missing key, or an authentication failure (the corrupt blob is then deleted so it re-fetches).
    public nonisolated func diskData(for uid: PhotoUID) -> Data? {
        guard retentionAuthorization.isAllowed(uid) else { return nil }
        let generation = writerGeneration.capture()
        let (cipher, account) = crypto.snapshot()
        guard let cipher else { return nil }  // locked
        let name = filename(uid: uid, account: account)
        let url = directory.appendingPathComponent(name)
        guard let blob = try? Data(contentsOf: url) else {
            // The cache directory may be purged while the process is alive. Never let a stale
            // validation proof suppress the network fallback after the file disappeared.
            validated.remove(name, generation: generation)
            return nil
        }
        guard let plaintext = cipher.open(blob, uid: uid) else {
            // The delete must join the generation fence. Otherwise an old auth failure can remove a new
            // generation's replacement blob after a destructive clear.
            _ = writerGeneration.performIfCurrent(generation) {
                try? FileManager.default.removeItem(at: url)  // Drop auth failures or corruption for a later refetch.
                validated.remove(name, generation: generation)
            }
            return nil
        }
        guard
            writerGeneration.performIfCurrent(
                generation,
                {
                    guard retentionAuthorization.isAllowed(uid) else { return false }
                    validated.insert(name, generation: generation)
                    return true
                }) == true
        else { return nil }
        return retentionAuthorization.isAllowed(uid) ? plaintext : nil
    }

    /// URL of the on-disk encrypted blob (bytes are ciphertext - not directly decodable).
    public nonisolated func diskURL(for uid: PhotoUID) -> URL {
        let (_, account) = crypto.snapshot()
        return directory.appendingPathComponent(filename(uid: uid, account: account))
    }

    /// Captures the current account/session generation for a detached loader or writer.
    public nonisolated func captureWriterGeneration() -> CacheWriterGeneration.Token {
        writerGeneration.capture()
    }

    /// Captures a writer token and the stable session lease atomically at owner construction.
    public nonisolated func captureLeases() -> (
        writer: CacheWriterGeneration.Token,
        session: CacheWriterGeneration.SessionToken
    ) {
        writerGeneration.captureLeases()
    }

    /// Captures the stable account/session lease for a long-lived feed, viewer, or provider owner. An ordinary
    /// cache clear keeps this lease valid; account reconfiguration and sign-out replace it.
    public nonisolated func captureSessionLease() -> CacheWriterGeneration.SessionToken {
        writerGeneration.captureSession()
    }

    /// Reports whether a captured generation still belongs to this account/session.
    public nonisolated func isCurrentWriterGeneration(_ generation: CacheWriterGeneration.Token) -> Bool {
        writerGeneration.isCurrent(generation)
    }

    /// Reports whether a long-lived owner still belongs to the configured account/session.
    public nonisolated func isCurrentSessionLease(_ lease: CacheWriterGeneration.SessionToken) -> Bool {
        writerGeneration.isCurrentSession(lease)
    }

    /// Account/derivative-scoped checkpoint storage for whole-library thumbnail coverage. Kept beside the
    /// encrypted cache and purged with it, so a cache clear can never leave stale "already cached" state.
    public nonisolated func coverageCheckpointDirectory() -> URL {
        coverageCheckpointDir
    }

    public nonisolated func coverageCheckpointScope() -> String {
        let (_, account) = crypto.snapshot()
        return "\(namespace)\u{1f}\(derivative)\u{1f}\(account)"
    }

    // MARK: - Writes

    public nonisolated func storeToDisk(_ data: Data, for uid: PhotoUID) {
        let generation = writerGeneration.capture()
        _ = storeToDisk(data, for: uid, ifCurrent: generation)
    }

    /// Stores encrypted bytes only when the caller's captured generation is still current.
    /// Distinguishes a successful write, a stale generation, and an I/O or locked-cache failure.
    @discardableResult
    public nonisolated func storeToDisk(
        _ data: Data,
        for uid: PhotoUID,
        ifCurrent generation: CacheWriterGeneration.Token
    ) -> ThumbnailCacheStoreResult {
        guard retentionAuthorization.isAllowed(uid) else { return .stale }
        let (cipher, account) = crypto.snapshot()
        // Never persist plaintext while the cache is locked.
        guard let cipher, let sealed = try? cipher.seal(data, uid: uid) else { return .ioFailure }
        let name = filename(uid: uid, account: account)
        let result: ThumbnailCacheStoreResult =
            writerGeneration.performIfCurrent(generation) {
                guard retentionAuthorization.isAllowed(uid) else {
                    return ThumbnailCacheStoreResult.stale
                }
                do {
                    try sealed.write(to: directory.appendingPathComponent(name), options: .atomic)
                    validated.insert(name, generation: generation)  // we just sealed it - it's decryptable
                    return ThumbnailCacheStoreResult.stored
                } catch {
                    validated.remove(name, generation: generation)
                    return ThumbnailCacheStoreResult.ioFailure
                }
            } ?? .stale
        if result == .stored, let automaticDiskCapBytes, let automaticDiskCapScheduler {
            // Use the current generation when the utility pass runs. A cache clear or account switch can happen
            // between this write and the trim; the new generation still needs its shared bound enforced.
            automaticDiskCapScheduler.schedule { [weak self] in
                self?.enforceByteCap(automaticDiskCapBytes)
            }
        }
        return result
    }

    public func store(_ data: Data, for uid: PhotoUID) {
        guard retentionAuthorization.isAllowed(uid) else { return }
        let generation = writerGeneration.capture()
        guard storeToDisk(data, for: uid, ifCurrent: generation) == .stored else {
            memory.removeObject(forKey: Self.memKey(uid))
            return
        }
        let published =
            writerGeneration.performIfCurrent(generation) {
                guard retentionAuthorization.isAllowed(uid) else { return false }
                // Plaintext remains process-local and is published only after the fenced encrypted write.
                memory.setObject(data as NSData, forKey: Self.memKey(uid), cost: data.count)
                return true
            } ?? false
        if !published { memory.removeObject(forKey: Self.memKey(uid)) }
    }

    // MARK: - LRU size cap

    /// Marks a blob as recently used (bumps its modification date) so LRU eviction keeps it. Called on a disk
    /// HIT for the originals cache only - never on the thumbnail/preview scrolling hot path.
    public nonisolated func touch(_ uid: PhotoUID) {
        let generation = writerGeneration.capture()
        _ = touch(uid, ifCurrent: generation)
    }

    /// Touches a blob only when the caller's operation still belongs to the active writer generation.
    @discardableResult
    public nonisolated func touch(
        _ uid: PhotoUID,
        ifCurrent generation: CacheWriterGeneration.Token
    ) -> Bool {
        guard retentionAuthorization.isAllowed(uid) else { return false }
        let (_, account) = crypto.snapshot()
        let url = directory.appendingPathComponent(filename(uid: uid, account: account))
        return writerGeneration.performIfCurrent(generation) {
            guard retentionAuthorization.isAllowed(uid) else { return false }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return true
        } ?? false
    }

    /// Evicts the least-recently-used blobs (oldest modification date first) until the directory is at or under
    /// `capBytes`. No-op when already within budget or when `capBytes` is negative (treated as "unbounded" guard).
    public nonisolated func enforceByteCap(_ capBytes: Int64) {
        let generation = writerGeneration.capture()
        _ = enforceByteCap(capBytes, ifCurrent: generation)
    }

    /// Applies the LRU cap only while the caller's captured generation remains current.
    @discardableResult
    public nonisolated func enforceByteCap(
        _ capBytes: Int64,
        ifCurrent generation: CacheWriterGeneration.Token
    ) -> Bool {
        guard writerGeneration.isCurrent(generation) else { return false }
        return enforceByteCapUnlocked(capBytes, generation: generation)
    }

    /// Waits for the coalesced automatic disk-cap pass. Production writes only schedule this utility work; tests
    /// and maintenance callers can await the boundary before asserting the on-disk byte bound.
    public nonisolated func flushAutomaticDiskCap() async {
        await automaticDiskCapScheduler?.wait()
    }

    private nonisolated func enforceByteCapUnlocked(
        _ capBytes: Int64,
        generation: CacheWriterGeneration.Token
    ) -> Bool {
        guard capBytes >= 0 else { return true }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            )
        else { return false }
        var entries: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for url in urls {
            let vals = try? url.resourceValues(forKeys: keys)
            let size = Int64(vals?.fileSize ?? 0)
            entries.append((url, size, vals?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > capBytes else { return writerGeneration.isCurrent(generation) }
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {  // oldest first
            if total <= capBytes { break }
            let removed =
                writerGeneration.performIfCurrent(generation) {
                    do {
                        try FileManager.default.removeItem(at: entry.url)
                        validated.remove(entry.url.lastPathComponent, generation: generation)
                        return true
                    } catch {
                        return false
                    }
                } ?? false
            guard removed else { return false }
            total -= entry.size
        }
        return writerGeneration.isCurrent(generation)
    }

    // MARK: - Clearing

    /// Binds source-aware reconciliation for the current account session.
    @discardableResult
    public nonisolated func bindDerivedDataEpoch(
        _ epoch: LibrarySourceEpoch,
        sessionLease: CacheWriterGeneration.SessionToken
    ) -> Bool {
        let bound = retentionScopeFence.bindIfNeeded(
            to: epoch,
            validating: { writerGeneration.isCurrentSession(sessionLease) }
        )
        if bound { retentionAuthorization.requireScope() }
        return bound
    }

    /// Reconciles encrypted blobs only when the scope is a complete current inventory.
    ///
    /// Cached, refreshing, and hydrating scopes can schedule additions. They cannot authorize deletion.
    /// A successful reconciliation also removes the coverage checkpoint because its prior completeness
    /// claim no longer matches the disk contents.
    @discardableResult
    public nonisolated func reconcile(
        with scope: ThumbnailRetentionDerivedDataScope
    ) -> MediaCacheReconciliationResult {
        let fenced = retentionScopeFence.perform(with: scope) { previousScope in
            guard scope.isAuthoritative else {
                retentionAuthorization.apply(scope)
                return (MediaCacheReconciliationResult.deferred, true)
            }
            if previousScope?.isAuthoritative == true, previousScope?.uids == scope.uids {
                retentionAuthorization.apply(scope)
                return (MediaCacheReconciliationResult.reconciled(removedEntries: 0), true)
            }

            // A complete first scope must sweep unknown files. Later complete scopes delete only the
            // membership delta. Add-only updates therefore stay O(1) and do not invalidate active readers.
            let removedUIDs: Set<PhotoUID>?
            if let previousScope, previousScope.isAuthoritative {
                removedUIDs = previousScope.uids.subtracting(scope.uids)
            } else {
                removedUIDs = nil
            }
            if removedUIDs?.isEmpty == true {
                retentionAuthorization.apply(scope)
                return (MediaCacheReconciliationResult.reconciled(removedEntries: 0), true)
            }

            let account = writerGeneration.invalidateAndPerform {
                // Finish any writer which already owns the old generation and revoke membership before
                // reopening captures. The slow unlink pass can then run without blocking retained reads or
                // writes; removed resources are rejected by both the new generation and authorization scope.
                retentionAuthorization.apply(scope)
                let (_, account) = crypto.snapshot()
                validated.clearAll()
                return account
            }.result
            var removedDiskFiles = 0
            var failed = false

            if let removedUIDs {
                for uid in removedUIDs {
                    let name = filename(uid: uid, account: account)
                    memory.removeObject(forKey: Self.memKey(uid))
                    let url = directory.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    do {
                        try FileManager.default.removeItem(at: url)
                        removedDiskFiles += 1
                    } catch {
                        failed = true
                    }
                }
            } else {
                let retainedFilenames = Set(scope.uids.map { filename(uid: $0, account: account) })
                do {
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                    let urls = try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                    for url in urls
                    where url.pathExtension == "blob"
                        && !retainedFilenames.contains(url.lastPathComponent)
                    {
                        do {
                            try FileManager.default.removeItem(at: url)
                            removedDiskFiles += 1
                        } catch {
                            failed = true
                        }
                    }
                } catch {
                    failed = true
                }
            }

            if !Self.removeDirectoryIfPresent(coverageCheckpointDir) {
                failed = true
            }
            let result: MediaCacheReconciliationResult =
                failed
                ? .ioFailure
                : .reconciled(removedEntries: removedDiskFiles)
            // Authorization changes immediately, but a failed cleanup must remain retryable with the same
            // revision. The fence still rejects every older revision while no cleanup revision is committed.
            return (result, result != .ioFailure)
        }
        switch fenced.decision {
        case .accepted:
            return fenced.value ?? .ioFailure
        case .unbound:
            return .unbound
        case .epochMismatch, .staleRevision:
            return .staleScope
        }
    }

    /// Erases the on-disk cache (keeps the account key - re-crawl refills). Used by "Delete Offline Cache".
    public func clear() {
        // Advance before removing files. A late non-cooperative loader can still invoke its callback,
        // but its captured token will fail the write fence instead of recreating stale data.
        writerGeneration.invalidateAndPerform {
            memory.removeAllObjects()
            validated.clearAll()
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: coverageCheckpointDir)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Sign-out purge: erases blobs and replaces the session-derived key with a fresh ephemeral key.
    public nonisolated func clearForSignOut() {
        retentionScopeFence.resetForSessionTransition {
            writerGeneration.invalidateAndPerform(invalidatesSession: true) {
                retentionAuthorization.reset()
                memory.removeAllObjects()
                validated.clearAll()
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.removeItem(at: coverageCheckpointDir)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                crypto.set(
                    cipher: SecureBlobCipher(
                        key: SymmetricKey(size: .bits256),
                        namespace: namespace,
                        accountUID: CryptoBox.ephemeralAccount,
                        derivative: derivative),
                    account: CryptoBox.ephemeralAccount
                )
            }
        }
    }

    // MARK: - Stats

    public nonisolated func diskCoverage(for uids: [PhotoUID]) -> (present: Int, total: Int, percent: Double) {
        let total = uids.count
        guard total > 0 else { return (0, 0, 1) }
        let present = uids.reduce(0) { $0 + (has($1) ? 1 : 0) }
        return (present, total, Double(present) / Double(total))
    }

    public nonisolated func diskFileCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    public nonisolated func diskSizeBytes() -> Int64 {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }
        return urls.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    // MARK: - Keys

    /// Account-scoped, content-hiding filename: SHA-256(namespace ‖ account ‖ volume ‖ node).blob. The node
    /// IDs never appear on the filesystem, and two accounts never collide.
    private nonisolated func filename(uid: PhotoUID, account: String) -> String {
        let material = "\(namespace)\u{1f}\(account)\u{1f}\(uid.volumeID)\u{1f}\(uid.nodeID)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return Self.lowercaseHex(digest) + ".blob"
    }

    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)

    private nonisolated static func lowercaseHex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var output: [UInt8] = []
        output.reserveCapacity(64)
        for byte in bytes {
            output.append(lowercaseHexDigits[Int(byte >> 4)])
            output.append(lowercaseHexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// In-RAM NSCache key (process-local plaintext tier; not security sensitive).
    private static func memKey(_ uid: PhotoUID) -> NSString {
        "\(uid.volumeID)~\(uid.nodeID)" as NSString
    }

    private static func defaultDerivative(for namespace: String) -> String {
        switch namespace {
        case "thumbnails": return "thumbnail"
        case "previews": return "preview"
        default: return namespace
        }
    }

    static func defaultDiskByteBudget(for derivative: String) -> Int64? {
        switch derivative {
        case "preview": return ThumbnailCacheConfiguration.defaultPreviewDiskBudgetBytes
        default: return nil
        }
    }

    private static func removeDirectoryIfPresent(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }
}

/// Coalesces automatic LRU scans so a burst of thumbnail writes creates one bounded utility pass, not one
/// directory enumeration per file. The lock protects state; the operation itself runs on a detached utility task.
private final class ThumbnailCacheDiskCapScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private let debounceDuration: Duration
    private var pending = false
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(debounceDuration: Duration = .milliseconds(150)) {
        self.debounceDuration = debounceDuration
    }

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        let shouldStart = lock.withLock {
            pending = true
            guard !running else { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        Task.detached(priority: .utility) { [self] in
            await drain(operation)
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let completeNow = lock.withLock {
                guard running || pending else { return true }
                waiters.append(continuation)
                return false
            }
            if completeNow { continuation.resume() }
        }
    }

    /// Delay the first scan long enough to absorb a write burst. If more writes arrive during a scan, one
    /// additional debounced pass enforces the final size instead of rescanning once per blob.
    private func drain(_ operation: @escaping @Sendable () -> Void) async {
        while true {
            try? await Task.sleep(for: debounceDuration)
            let shouldRun = lock.withLock {
                guard pending else { return false }
                pending = false
                return true
            }
            if shouldRun { operation() }

            let completion = lock.withLock { () -> [CheckedContinuation<Void, Never>]? in
                guard !pending else { return nil }
                running = false
                let completion = waiters
                waiters.removeAll(keepingCapacity: false)
                return completion
            }
            guard let completion else { continue }
            completion.forEach { $0.resume() }
            return
        }
    }
}

/// Thread-safe holder for the active cipher + account so the cache's many `nonisolated` accessors can read
/// the current crypto context without an actor hop. `configure`/`clearForSignOut` swap it atomically.
private final class CryptoBox: @unchecked Sendable {
    static let ephemeralAccount = "(unconfigured)"
    private let lock = NSLock()
    private var cipher: SecureBlobCipher?
    private var account: String

    init(cipher: SecureBlobCipher?, account: String) {
        self.cipher = cipher
        self.account = account
    }

    func snapshot() -> (SecureBlobCipher?, String) { lock.withLock { (cipher, account) } }
    func set(cipher: SecureBlobCipher?, account: String) {
        lock.withLock {
            self.cipher = cipher
            self.account = account
        }
    }
}

/// Thread-safe set of blob filenames proven decryptable this session, so `hasUsableDiskData` only pays the
/// decrypt-probe once per file.
private final class ValidatedPresence: @unchecked Sendable {
    private let lock = NSLock()
    private var good: [CacheWriterGeneration.Token: Set<String>] = [:]

    func contains(_ name: String, generation: CacheWriterGeneration.Token) -> Bool {
        lock.withLock { good[generation]?.contains(name) == true }
    }

    func insert(_ name: String, generation: CacheWriterGeneration.Token) {
        _ = lock.withLock { good[generation, default: []].insert(name) }
    }

    func remove(_ name: String, generation: CacheWriterGeneration.Token) {
        lock.withLock {
            guard good[generation]?.remove(name) != nil else { return }
            if good[generation]?.isEmpty == true { good.removeValue(forKey: generation) }
        }
    }

    func clearAll() { lock.withLock { good.removeAll() } }
}
