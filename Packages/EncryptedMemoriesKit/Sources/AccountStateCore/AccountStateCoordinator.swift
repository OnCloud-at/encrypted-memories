import DeviceRootCore
import Foundation

/// Why critical state is closed. Local data stays untouched in every case.
public enum AccountStateClosedReason: Equatable, Sendable {
    /// No state exists yet. Only the device that performs the first setup creates it.
    case notInitialized
    /// The state existed and is gone for good. Only a reset that the owner confirmed recreates it.
    case missing
    case damaged
    case rejected(AccountStateRejection)
    case verificationFailed
    /// A file without a committed revision, for example after an interrupted first upload.
    case incomplete
    case oversized
    case ambiguousRoot
    /// Other writers kept changing the state until the retry limit.
    case contention
    case quota
    case localCopyUnavailable
    /// The local copy belongs to another account, root incarnation, or state. It is neither merged nor replaced.
    case foreignLocalCopy
    /// The account, Labs, or wipe generation changed during the step. Its result was ignored.
    case fenced
}

public enum AccountStateStatus: Equatable, Sendable {
    /// Verified, current, and writable.
    case ready(AccountStateDocument)
    /// A newer format. This build neither changes nor replaces it.
    case readOnly(format: Int)
    /// The state moved to another location. This build never writes here again.
    case moved(AccountStateDocument)
    /// The check could not run now. The last local copy is not proof of the current state.
    case unavailable(lastKnown: AccountStateDocument?)
    case closed(AccountStateClosedReason)
}

/// Critical writes stay off until the storage adapter proves a service-enforced compare-and-swap.
public struct AccountStateWritesUnsupportedError: Error, Equatable {}

/// Reads, verifies, merges, and writes the account state document.
///
/// Every write persists the local copy first and then uses compare-and-swap against the revision it just read. A
/// conflict or an unknown outcome leads to a fresh read and merge; because the document merges safely, a repeated
/// write never loses or duplicates a change. Anything this build cannot prove keeps writes closed. The coordinator
/// runs one operation at a time.
public actor AccountStateCoordinator {
    public struct Configuration: Sendable {
        public var criticalWritesEnabled: Bool
        public var deviceID: String
        public var maximumWriteAttempts: Int
        /// The largest sealed file or document this build reads or writes.
        public var maximumBytes: Int

        public init(
            criticalWritesEnabled: Bool, deviceID: String, maximumWriteAttempts: Int = 5,
            maximumBytes: Int = 1 << 20
        ) {
            self.criticalWritesEnabled = criticalWritesEnabled
            self.deviceID = deviceID
            self.maximumWriteAttempts = max(1, maximumWriteAttempts)
            self.maximumBytes = maximumBytes
        }
    }

    private struct RemoteSnapshot {
        let item: DeviceRootItem
        let sealed: Data
        let document: AccountStateDocument
    }

    private enum RemoteRead {
        case present(RemoteSnapshot)
        case absent
        case status(AccountStateStatus)
    }

    private let store: any DeviceRootStore
    private let path: DeviceRootPath
    private let sealer: any AccountStateSealing
    private let local: any AccountStateLocalStore
    private let binding: AccountStateBinding
    private let configuration: Configuration
    private let isCurrent: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let backoff: @Sendable (Int) async throws -> Void
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - isCurrent: False once the account, Labs, Smart Search, or wipe generation changed. The coordinator
    ///     checks it before every side effect and ignores results that arrive afterwards.
    ///   - backoff: Waits before retry number `attempt`. The default grows exponentially with jitter.
    public init(
        store: any DeviceRootStore, path: DeviceRootPath, sealer: any AccountStateSealing,
        local: any AccountStateLocalStore, binding: AccountStateBinding, configuration: Configuration,
        isCurrent: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() },
        backoff: @escaping @Sendable (Int) async throws -> Void = { try await exponentialBackoff(attempt: $0) }
    ) {
        self.store = store
        self.path = path
        self.sealer = sealer
        self.local = local
        self.binding = binding
        self.configuration = configuration
        self.isCurrent = isCurrent
        self.now = now
        self.backoff = backoff
    }

    public nonisolated static func exponentialBackoff(attempt: Int) async throws {
        let base = min(30.0, 0.5 * pow(2.0, Double(max(0, attempt - 1))))
        try await Task.sleep(nanoseconds: UInt64((base + Double.random(in: 0...base)) * 1_000_000_000))
    }

    /// Reads and verifies the state, merges it with the local copy, and publishes local changes that no remote
    /// revision contains yet.
    public func refresh() async -> AccountStateStatus {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return .unavailable(lastKnown: nil) }
        return await synchronize(change: nil)
    }

    /// Applies a change to a freshly verified state and publishes it. Without a verified current state the change
    /// is not applied, and the returned status says why. Only errors of `change` itself are thrown.
    public func update(
        _ change: @escaping @Sendable (inout AccountStateDocument) throws -> Void
    ) async throws -> AccountStateStatus {
        guard configuration.criticalWritesEnabled else { throw AccountStateWritesUnsupportedError() }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return .unavailable(lastKnown: nil) }
        return try await synchronizeThrowing(change: change)
    }

    /// Creates the state during the explicit first setup on one device. Another device never calls this; an existing
    /// state is merged instead, and a lost state stays closed.
    public func initialize() async throws -> AccountStateStatus {
        guard configuration.criticalWritesEnabled else { throw AccountStateWritesUnsupportedError() }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return .unavailable(lastKnown: nil) }
        let record: AccountStateLocalRecord?
        switch await loadLocal() {
        case .record(let loaded): record = loaded
        case .status(let status): return status
        }
        switch await readRemote() {
        case .status(let status):
            return withLastKnown(status, record: record)
        case .present:
            return await synchronize(change: nil)
        case .absent:
            guard record?.published != true else { return .closed(.missing) }
            guard let record else { return await create(AccountStateDocument(), basedOn: nil, published: false) }
            // A local copy can stem from an earlier create whose settlement was lost before the state vanished, so
            // it cannot prove a true first setup. It is recreated like an owner reset, with sharing off.
            guard var document = decodeLocal(record) else { return .closed(.localCopyUnavailable) }
            if document.movedTo != nil { return .moved(document) }
            try turnSharingOff(in: &document)
            return await create(document, basedOn: record.lastSealed, published: false)
        }
    }

    /// Recreates a lost state from the local copy after the owner confirmed it. The local copy cannot prove that no
    /// other device wrote a newer state before the loss, so the reset turns sharing off.
    public func resetFromLocalCopy() async throws -> AccountStateStatus {
        guard configuration.criticalWritesEnabled else { throw AccountStateWritesUnsupportedError() }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return .unavailable(lastKnown: nil) }
        let record: AccountStateLocalRecord?
        switch await loadLocal() {
        case .record(let loaded): record = loaded
        case .status(let status): return status
        }
        switch await readRemote() {
        case .status(let status):
            return withLastKnown(status, record: record)
        case .present:
            return await synchronize(change: nil)
        case .absent:
            guard let record, record.published else { return .closed(.notInitialized) }
            guard var document = decodeLocal(record) else { return .closed(.localCopyUnavailable) }
            if document.movedTo != nil { return .moved(document) }
            try turnSharingOff(in: &document)
            return await create(document, basedOn: record.lastSealed, published: true)
        }
    }

    // MARK: - Steps

    private func synchronize(
        change: (@Sendable (inout AccountStateDocument) throws -> Void)?
    ) async
        -> AccountStateStatus
    {
        (try? await synchronizeThrowing(change: change)) ?? .unavailable(lastKnown: nil)
    }

    private func synchronizeThrowing(
        change: (@Sendable (inout AccountStateDocument) throws -> Void)?
    ) async throws -> AccountStateStatus {
        let record: AccountStateLocalRecord?
        switch await loadLocal() {
        case .record(let loaded): record = loaded
        case .status(let status): return status
        }

        let snapshot: RemoteSnapshot
        switch await readRemote() {
        case .status(let status): return withLastKnown(status, record: record)
        case .absent: return .closed(record?.published == true ? .missing : .notInitialized)
        case .present(let present): snapshot = present
        }

        guard let merged = merge(decodeLocal(record), snapshot.document) else { return .closed(.damaged) }
        var next = merged
        if let change, merged.movedTo == nil { try change(&next) }
        guard let bytes = try? next.encoded() else { return .closed(.damaged) }
        guard bytes.count <= configuration.maximumBytes else { return .closed(.oversized) }
        guard isCurrent() else { return .closed(.fenced) }
        let unpublished = next != snapshot.document
        do {
            try await local.save(
                AccountStateLocalRecord(
                    binding: binding, document: bytes, lastSealed: snapshot.sealed, published: true,
                    hasUnpublishedChanges: unpublished))
        } catch {
            return .closed(.localCopyUnavailable)
        }
        guard isCurrent() else { return .closed(.fenced) }
        if next.movedTo != nil { return .moved(next) }
        guard unpublished, configuration.criticalWritesEnabled else { return .ready(next) }
        return await publish(next, base: snapshot, basedOn: snapshot.sealed)
    }

    /// Creates the first file, or recreates a lost one, with create-if-absent.
    /// `published` keeps whether the state existed before, so a reset that fails before it is sent can run again.
    private func create(
        _ document: AccountStateDocument, basedOn previous: Data?, published: Bool
    ) async -> AccountStateStatus {
        // A moved state is never written at the old location, not even to recreate it.
        if document.movedTo != nil { return .moved(document) }
        guard let bytes = try? document.encoded() else { return .closed(.damaged) }
        do {
            try await local.save(
                AccountStateLocalRecord(
                    binding: binding,
                    document: bytes, lastSealed: previous, published: published, hasUnpublishedChanges: true))
        } catch {
            return .closed(.localCopyUnavailable)
        }
        return await publish(document, base: nil, basedOn: previous)
    }

    /// Writes with compare-and-swap until the remote state contains `document`, within the attempt limit.
    private func publish(
        _ document: AccountStateDocument, base initialBase: RemoteSnapshot?, basedOn initialSealed: Data?
    ) async -> AccountStateStatus {
        var document = document
        var base = initialBase
        var basedOn = initialSealed
        for attempt in 1...configuration.maximumWriteAttempts {
            guard isCurrent() else { return .closed(.fenced) }
            guard !Task.isCancelled else { return .unavailable(lastKnown: document) }
            guard let bytes = try? document.encoded() else { return .closed(.damaged) }
            let sealed: Data
            do {
                sealed = try await sealer.seal(bytes, binding: binding, basedOn: basedOn)
            } catch {
                return .unavailable(lastKnown: document)
            }
            guard sealed.count <= configuration.maximumBytes else { return .closed(.oversized) }
            guard isCurrent() else { return .closed(.fenced) }
            guard !Task.isCancelled else { return .unavailable(lastKnown: document) }

            do {
                _ = try await store.compareAndSwap(
                    at: path, expectedRevisionUID: base?.item.activeRevisionUID, bytes: sealed)
                guard isCurrent() else { return .closed(.fenced) }
                // A failed save keeps the unpublished mark; the next read finds this revision and settles it.
                try? await local.save(
                    AccountStateLocalRecord(
                        binding: binding,
                        document: bytes, lastSealed: sealed, published: true, hasUnpublishedChanges: false))
                guard isCurrent() else { return .closed(.fenced) }
                return .ready(document)
            } catch DeviceRootOperationError.conflict, DeviceRootOperationError.unknownOutcome {
                // Resolve against the current revision below.
            } catch DeviceRootOperationError.quota {
                return .closed(.quota)
            } catch DeviceRootOperationError.verificationFailed {
                return .closed(.verificationFailed)
            } catch DeviceRootOperationError.ambiguousRoot {
                return .closed(.ambiguousRoot)
            } catch is DeviceRootOperationError {
                // Not sent, unavailable, throttled, or unsupported: the intent stays in the local copy.
                return .unavailable(lastKnown: document)
            } catch is CancellationError {
                return .unavailable(lastKnown: document)
            } catch {
                // An unknown SDK error may have reached the service. Resolve before any retry.
            }

            guard attempt < configuration.maximumWriteAttempts else { return .closed(.contention) }
            do { try await backoff(attempt) } catch { return .unavailable(lastKnown: document) }

            switch await readRemote() {
            case .status(let status):
                return withLastKnown(status, document: document)
            case .absent:
                // A create that did not arrive is retried; a file that vanished after it existed stays closed.
                guard base == nil else { return .closed(.missing) }
            case .present(let snapshot):
                guard let merged = merge(document, snapshot.document), let mergedBytes = try? merged.encoded() else {
                    return .closed(.damaged)
                }
                document = merged
                base = snapshot
                basedOn = snapshot.sealed
                let settled = merged == snapshot.document
                guard isCurrent() else { return .closed(.fenced) }
                // The merge holds another writer's changes; a retry without a durable copy could lose them.
                do {
                    try await local.save(
                        AccountStateLocalRecord(
                            binding: binding, document: mergedBytes, lastSealed: snapshot.sealed, published: true,
                            hasUnpublishedChanges: !settled))
                } catch {
                    return .closed(.localCopyUnavailable)
                }
                guard isCurrent() else { return .closed(.fenced) }
                if merged.movedTo != nil { return .moved(merged) }
                if settled { return .ready(merged) }
            }
        }
        return .closed(.contention)
    }

    /// Reads, restores from the trash when needed, verifies, and opens the state file.
    private func readRemote() async -> RemoteRead {
        var restored = false
        var conflicts = 0
        while true {
            guard isCurrent() else { return .status(.closed(.fenced)) }
            let result: DeviceRootReadResult?
            do {
                result = try await store.read(at: path)
            } catch DeviceRootOperationError.conflict where conflicts < 2 {
                conflicts += 1
                continue
            } catch {
                return .status(Self.status(forReadError: error))
            }
            guard isCurrent() else { return .status(.closed(.fenced)) }
            guard let result else { return .absent }
            // The file is checked before a restore, so a foreign, damaged, newer, or moved state never changes the
            // server.
            let checked = await check(result)
            guard result.item.isTrashed, case .present(let snapshot) = checked, snapshot.document.movedTo == nil
            else { return checked }
            // A restore changes the server, so it waits until critical writes are allowed.
            guard configuration.criticalWritesEnabled, !restored, !Task.isCancelled else {
                return .status(.unavailable(lastKnown: nil))
            }
            do {
                _ = try await store.restore(item: result.item)
            } catch DeviceRootOperationError.unknownOutcome, DeviceRootOperationError.conflict {
                // The next read shows whether the restore arrived.
            } catch {
                return .status(Self.status(forReadError: error))
            }
            restored = true
        }
    }

    /// Verifies and opens one read of the state file.
    private func check(_ result: DeviceRootReadResult) async -> RemoteRead {
        guard result.item.activeRevisionUID != nil else { return .status(.closed(.incomplete)) }
        guard result.verification == .verified else { return .status(.closed(.verificationFailed)) }
        guard result.bytes.count <= configuration.maximumBytes else { return .status(.closed(.oversized)) }

        let opened: AccountStateOpenResult
        do {
            opened = try await sealer.open(result.bytes, binding: binding)
        } catch {
            return .status(.unavailable(lastKnown: nil))
        }
        guard isCurrent() else { return .status(.closed(.fenced)) }
        switch opened {
        case .newerFormat(let format):
            return .status(.readOnly(format: format))
        case .rejected(let rejection):
            return .status(.closed(.rejected(rejection)))
        case .opened(let data):
            guard data.count <= configuration.maximumBytes else { return .status(.closed(.oversized)) }
            guard let document = try? AccountStateDocument(data: data) else {
                return .status(.closed(.damaged))
            }
            guard document.isSupported else { return .status(.readOnly(format: document.format)) }
            guard !document.isDamaged else { return .status(.closed(.damaged)) }
            return .present(RemoteSnapshot(item: result.item, sealed: result.bytes, document: document))
        }
    }

    private static func status(forReadError error: Error) -> AccountStateStatus {
        switch error as? DeviceRootOperationError {
        case .ambiguousRoot?: .closed(.ambiguousRoot)
        case .verificationFailed?: .closed(.verificationFailed)
        case .quota?: .closed(.quota)
        default: .unavailable(lastKnown: nil)
        }
    }

    // MARK: - Helpers

    private func turnSharingOff(in document: inout AccountStateDocument) throws {
        guard document.value(for: .sharedLibraryEnabled) != false else { return }
        try document.setValue(false, for: .sharedLibraryEnabled, at: now(), deviceID: configuration.deviceID)
    }

    private enum LocalLoad {
        case record(AccountStateLocalRecord?)
        case status(AccountStateStatus)
    }

    /// The local copy of this binding. A copy that is unreadable, damaged, or bound elsewhere closes the state.
    private func loadLocal() async -> LocalLoad {
        let record: AccountStateLocalRecord?
        do { record = try await local.load() } catch { return .status(.closed(.localCopyUnavailable)) }
        guard let record else { return .record(nil) }
        guard record.binding == binding else { return .status(.closed(.foreignLocalCopy)) }
        guard decodeLocal(record) != nil else { return .status(.closed(.localCopyUnavailable)) }
        return .record(record)
    }

    private func merge(_ local: AccountStateDocument?, _ remote: AccountStateDocument) -> AccountStateDocument? {
        guard let local else { return remote }
        return AccountStateDocument.merged(local, remote)
    }

    private func decodeLocal(_ record: AccountStateLocalRecord?) -> AccountStateDocument? {
        guard let record, let document = try? AccountStateDocument(data: record.document), document.isUsable else {
            return nil
        }
        return document
    }

    private func withLastKnown(_ status: AccountStateStatus, record: AccountStateLocalRecord?) -> AccountStateStatus {
        withLastKnown(status, document: decodeLocal(record))
    }

    private func withLastKnown(_ status: AccountStateStatus, document: AccountStateDocument?) -> AccountStateStatus {
        if case .unavailable = status { return .unavailable(lastKnown: document) }
        return status
    }

    private func acquire() async {
        if isBusy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isBusy = true
        }
    }

    /// Hands the turn to the next waiting operation, or frees the coordinator.
    private func release() {
        if waiters.isEmpty { isBusy = false } else { waiters.removeFirst().resume() }
    }
}
