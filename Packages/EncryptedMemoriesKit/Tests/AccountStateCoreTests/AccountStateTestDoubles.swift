import DeviceRootCore
import Foundation
import PhotosCore

@testable import AccountStateCore

struct TestFailure: Error {}

let testBinding = AccountStateBinding(accountID: "account", rootIncarnation: "incarnation", stateID: "state")

/// What one call of the fake store does before, instead of, or after its normal effect.
enum StoreFault: Sendable {
    /// Fails without any server effect.
    case fail(Error)
    /// Applies the call, then loses the response.
    case applyThenFail(Error)
    /// Another device writes this document first; the call then runs against the new revision.
    case competingWrite(AccountStateDocument)
    /// The file lands in the trash before the call runs.
    case trashFirst
    /// Returns the result with a failed download verification.
    case failedVerification
    /// Runs normally.
    case pass
    /// Runs the closure, for example a fence change, and then the call as usual.
    case sideEffect(@Sendable () -> Void)
}

/// An in-memory state file with one active revision, fault injection, and a call log.
final class FakeStateStore: DeviceRootStore, @unchecked Sendable {
    struct File {
        var revision: Int
        var bytes: Data
        var isTrashed = false
        var hasCommittedRevision = true
    }

    private let lock = NSLock()
    private var file: File?
    private var readFaults: [StoreFault] = []
    private var writeFaults: [StoreFault] = []
    private var restoreFaults: [StoreFault] = []
    private(set) var writeAttempts = 0
    private(set) var appliedWrites = 0
    private(set) var restores = 0
    private(set) var reads = 0
    let sealer: FakeSealer
    let path = try! DeviceRootPath("State/account-state")

    init(sealer: FakeSealer) { self.sealer = sealer }

    func seed(_ document: AccountStateDocument) {
        lock.withLock { file = File(revision: 1, bytes: sealer.sealDirect(document)) }
    }

    func seedRaw(_ bytes: Data, committed: Bool = true) {
        lock.withLock { file = File(revision: 1, bytes: bytes, hasCommittedRevision: committed) }
    }

    /// Another device writes without compare-and-swap, as a test setup step.
    func externalWrite(_ document: AccountStateDocument) {
        lock.withLock {
            let revision = (file?.revision ?? 0) + 1
            file = File(revision: revision, bytes: sealer.sealDirect(document))
        }
    }

    func trash() { lock.withLock { file?.isTrashed = true } }
    func deletePermanently() { lock.withLock { file = nil } }
    func addReadFaults(_ faults: StoreFault...) { lock.withLock { readFaults += faults } }
    func addWriteFaults(_ faults: StoreFault...) { lock.withLock { writeFaults += faults } }
    func addRestoreFaults(_ faults: StoreFault...) { lock.withLock { restoreFaults += faults } }

    var isTrashed: Bool { lock.withLock { file?.isTrashed ?? false } }
    var exists: Bool { lock.withLock { file != nil } }
    var revision: Int? { lock.withLock { file?.revision } }

    /// The document that the server holds now.
    var remoteDocument: AccountStateDocument? {
        lock.withLock { file.flatMap { sealer.openDirect($0.bytes) } }
    }

    private func item(_ file: File) -> DeviceRootItem {
        DeviceRootItem(
            path: path, nodeUID: "state-node",
            activeRevisionUID: file.hasCommittedRevision ? "r\(file.revision)" : nil,
            chargedBytes: Int64(file.bytes.count), isFolder: false, isTrashed: file.isTrashed)
    }

    private func nextFault(_ queue: inout [StoreFault]) -> StoreFault? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    func read(at path: DeviceRootPath) async throws -> DeviceRootReadResult? {
        try lock.withLock {
            reads += 1
            var verification = DeviceRootVerification.verified
            switch nextFault(&readFaults) {
            case .fail(let error)?, .applyThenFail(let error)?: throw error
            case .competingWrite(let document)?:
                file = File(revision: (file?.revision ?? 0) + 1, bytes: sealer.sealDirect(document))
            case .trashFirst?: file?.isTrashed = true
            case .failedVerification?: verification = .failed
            case .sideEffect(let effect)?: effect()
            case .pass?, nil: break
            }
            guard let file else { return nil }
            return DeviceRootReadResult(item: item(file), bytes: file.bytes, verification: verification)
        }
    }

    func compareAndSwap(
        at path: DeviceRootPath, expectedRevisionUID: String?, bytes: Data
    ) async throws
        -> DeviceRootItem
    {
        try lock.withLock {
            writeAttempts += 1
            var loseResponse: Error?
            switch nextFault(&writeFaults) {
            case .fail(let error)?: throw error
            case .applyThenFail(let error)?: loseResponse = error
            case .competingWrite(let document)?:
                file = File(revision: (file?.revision ?? 0) + 1, bytes: sealer.sealDirect(document))
            case .trashFirst?: file?.isTrashed = true
            case .sideEffect(let effect)?: effect()
            case .failedVerification?, .pass?, nil: break
            }
            if let current = file {
                guard !current.isTrashed, expectedRevisionUID == "r\(current.revision)" else {
                    throw DeviceRootOperationError.conflict
                }
                file = File(revision: current.revision + 1, bytes: bytes)
            } else {
                guard expectedRevisionUID == nil else { throw DeviceRootOperationError.conflict }
                file = File(revision: 1, bytes: bytes)
            }
            appliedWrites += 1
            if let loseResponse { throw loseResponse }
            return item(file!)
        }
    }

    func restore(item: DeviceRootItem) async throws -> DeviceRootItem {
        try lock.withLock {
            restores += 1
            var loseResponse: Error?
            switch nextFault(&restoreFaults) {
            case .fail(let error)?: throw error
            case .applyThenFail(let error)?: loseResponse = error
            case .competingWrite(let document)?:
                file = File(revision: (file?.revision ?? 0) + 1, bytes: sealer.sealDirect(document), isTrashed: true)
            case .sideEffect(let effect)?: effect()
            case .trashFirst?, .failedVerification?, .pass?, nil: break
            }
            guard file != nil else { throw DeviceRootOperationError.unavailable }
            file?.isTrashed = false
            if let loseResponse { throw loseResponse }
            return self.item(file!)
        }
    }

    func inventory(at path: DeviceRootPath) async throws -> DeviceRootInventory {
        lock.withLock { DeviceRootInventory(items: file.map { [item($0)] } ?? [], isComplete: true, serverTime: nil) }
    }

    func putImmutable(at path: DeviceRootPath, expectedSHA256: String, bytes: Data) async throws -> DeviceRootItem {
        throw DeviceRootOperationError.unsupported
    }

    func trashOwn(item: DeviceRootItem) async throws { trash() }
    func deleteOwnFromTrash(item: DeviceRootItem) async throws { deletePermanently() }
}

/// Seals as "S<format>|<account>|<root>|<state>|<key>|<document>". Real encryption is an adapter concern.
final class FakeSealer: AccountStateSealing, @unchecked Sendable {
    private let lock = NSLock()
    private var nextKey = 0
    var binding = testBinding
    var onSeal: (@Sendable () -> Void)?
    var openOverride: AccountStateOpenResult?
    var openThrows = false
    var sealThrows = false
    private(set) var keysUsed: [String] = []

    func sealDirect(_ document: AccountStateDocument, key: String = "k0", format: Int = 1) -> Data {
        seal(bytes: try! document.encoded(), key: key, format: format, binding: binding)
    }

    func openDirect(_ sealed: Data) -> AccountStateDocument? {
        guard let parts = parse(sealed) else { return nil }
        return try? AccountStateDocument(data: parts.document)
    }

    func key(of sealed: Data) -> String? { parse(sealed)?.key }

    private func seal(bytes: Data, key: String, format: Int, binding: AccountStateBinding) -> Data {
        Data("S\(format)|\(binding.accountID)|\(binding.rootIncarnation)|\(binding.stateID)|\(key)|".utf8) + bytes
    }

    private func parse(_ sealed: Data) -> (format: Int, binding: AccountStateBinding, key: String, document: Data)? {
        let fields = sealed.split(separator: UInt8(ascii: "|"), maxSplits: 5, omittingEmptySubsequences: false)
        guard fields.count == 6, let first = fields.first, first.first == UInt8(ascii: "S"),
            let format = Int(String(decoding: first.dropFirst(), as: UTF8.self))
        else { return nil }
        let text = fields[1...4].map { String(decoding: $0, as: UTF8.self) }
        return (
            format, AccountStateBinding(accountID: text[0], rootIncarnation: text[1], stateID: text[2]), text[3],
            Data(fields[5])
        )
    }

    func open(_ sealed: Data, binding: AccountStateBinding) async throws -> AccountStateOpenResult {
        if openThrows { throw TestFailure() }
        if let openOverride { return openOverride }
        guard let parts = parse(sealed) else { return .rejected(.malformed) }
        guard parts.format <= 1 else { return .newerFormat(parts.format) }
        guard parts.binding == binding else { return .rejected(.wrongBinding) }
        return .opened(parts.document)
    }

    func seal(_ document: Data, binding: AccountStateBinding, basedOn previous: Data?) async throws -> Data {
        if sealThrows { throw TestFailure() }
        onSeal?()
        let key = lock.withLock {
            if let previous, let existing = parse(previous)?.key { return existing }
            nextKey += 1
            return "new\(nextKey)"
        }
        lock.withLock { keysUsed.append(key) }
        return seal(bytes: document, key: key, format: 1, binding: binding)
    }
}

final class FakeLocalStore: AccountStateLocalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AccountStateLocalRecord?
    var failLoad = false
    var failSave = false
    /// Saves fail once this many succeeded.
    var failSavesAfter: Int?
    /// Runs before each save, for example a fence change.
    var onSave: (@Sendable () -> Void)?
    private(set) var saves = 0

    init(_ record: AccountStateLocalRecord? = nil) { stored = record }

    /// Test setup: replaces the record without counting a save.
    func set(_ record: AccountStateLocalRecord?) { lock.withLock { stored = record } }

    var record: AccountStateLocalRecord? { lock.withLock { stored } }
    var document: AccountStateDocument? { record.flatMap { try? AccountStateDocument(data: $0.document) } }

    func load() async throws -> AccountStateLocalRecord? {
        if failLoad { throw TestFailure() }
        return record
    }

    func save(_ record: AccountStateLocalRecord) async throws {
        onSave?()
        if failSave { throw TestFailure() }
        if let failSavesAfter, lock.withLock({ saves >= failSavesAfter }) { throw TestFailure() }
        lock.withLock {
            saves += 1
            stored = record
        }
    }
}

final class Fence: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var isCurrent: Bool {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

let photoA = PhotoUID(volumeID: "volume", nodeID: "a")
let photoB = PhotoUID(volumeID: "volume", nodeID: "b")
let photoC = PhotoUID(volumeID: "volume", nodeID: "c")

func stateDate(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

func documentHiding(_ photos: [PhotoUID], device: String = "mac", start: Int64 = 1_000) throws -> AccountStateDocument {
    var document = AccountStateDocument()
    for (offset, photo) in photos.enumerated() {
        try document.setHidden(photo, true, at: stateDate(start + Int64(offset)), deviceID: device, nonce: 1)
    }
    return document
}

func hiding(
    _ photo: PhotoUID, at time: Int64 = 5_000, device: String = "iphone"
)
    -> @Sendable (inout AccountStateDocument) throws -> Void
{
    { try $0.setHidden(photo, true, at: stateDate(time), deviceID: device, nonce: 7) }
}

/// A store, local copy, sealer, fence, and coordinator that share one state.
struct Harness {
    let sealer = FakeSealer()
    let store: FakeStateStore
    let local: FakeLocalStore
    let fence = Fence()
    let writesEnabled: Bool
    let maximumAttempts: Int

    init(writesEnabled: Bool = true, maximumAttempts: Int = 4, local: FakeLocalStore = FakeLocalStore()) {
        store = FakeStateStore(sealer: sealer)
        self.local = local
        self.writesEnabled = writesEnabled
        self.maximumAttempts = maximumAttempts
    }

    /// A published state hiding photo A on the server and in the local copy.
    static func published(writesEnabled: Bool = true, maximumAttempts: Int = 4) throws -> Harness {
        let harness = Harness(writesEnabled: writesEnabled, maximumAttempts: maximumAttempts)
        let document = try documentHiding([photoA])
        harness.store.seed(document)
        harness.local.set(
            AccountStateLocalRecord(
                binding: testBinding, document: try document.encoded(), lastSealed: harness.sealer.sealDirect(document),
                published: true,
                hasUnpublishedChanges: false))
        return harness
    }

    /// A new coordinator on the same state, as after a restart.
    func coordinator(maximumBytes: Int = 1 << 20) -> AccountStateCoordinator {
        let fence = fence
        return AccountStateCoordinator(
            store: store, path: store.path, sealer: sealer, local: local, binding: sealer.binding,
            configuration: .init(
                criticalWritesEnabled: writesEnabled, deviceID: "iphone", maximumWriteAttempts: maximumAttempts,
                maximumBytes: maximumBytes),
            isCurrent: { fence.isCurrent }, now: { stateDate(9_000) }, backoff: { _ in })
    }
}

extension AccountStateStatus {
    var document: AccountStateDocument? {
        switch self {
        case .ready(let document), .moved(let document): document
        case .unavailable(let lastKnown): lastKnown
        case .readOnly, .closed: nil
        }
    }

    var isReady: Bool { if case .ready = self { true } else { false } }
    var isUnavailable: Bool { if case .unavailable = self { true } else { false } }
}
