import Foundation

/// Stable item identity for a node below the adapter's selected root.
public struct DeviceRootItem: Equatable, Sendable {
    public let path: DeviceRootPath
    public let nodeUID: String
    public let activeRevisionUID: String?
    public let chargedBytes: Int64
    public let isFolder: Bool

    public init(
        path: DeviceRootPath, nodeUID: String, activeRevisionUID: String?,
        chargedBytes: Int64, isFolder: Bool
    ) {
        self.path = path
        self.nodeUID = nodeUID
        self.activeRevisionUID = activeRevisionUID
        self.chargedBytes = chargedBytes
        self.isFolder = isFolder
    }
}

/// Only a complete inventory can authorize a new upload or destructive reconciliation.
public struct DeviceRootInventory: Sendable {
    public let items: [DeviceRootItem]
    public let isComplete: Bool
    public let serverTime: Date?

    public init(items: [DeviceRootItem], isComplete: Bool, serverTime: Date?) {
        self.items = items
        self.isComplete = isComplete
        self.serverTime = serverTime
    }
}

public enum DeviceRootVerification: Equatable, Sendable {
    case verified
    case failed
}

public struct DeviceRootReadResult: Sendable {
    public let item: DeviceRootItem
    public let bytes: Data
    public let verification: DeviceRootVerification

    public init(item: DeviceRootItem, bytes: Data, verification: DeviceRootVerification) {
        self.item = item
        self.bytes = bytes
        self.verification = verification
    }
}

/// An unknown mutation outcome remains unresolved until a fresh read proves what happened.
public enum DeviceRootOperationError: Error, Equatable {
    case unavailable
    case ambiguousRoot
    case conflict
    case quota
    case verificationFailed
    case unknownOutcome
    /// The adapter proves that the create request was never submitted.
    case notDispatched
    case unsupported
}

/// The only remote-storage surface visible to feature modules.
///
/// Every path is relative to the adapter's selected root. The adapter binds the account and writer
/// instance at construction, then checks actual node ancestry and root incarnation before mutation.
/// A nil expected revision means create only if absent.
public protocol DeviceRootStore: Sendable {
    func inventory(at path: DeviceRootPath) async throws -> DeviceRootInventory
    func read(at path: DeviceRootPath) async throws -> DeviceRootReadResult?
    func compareAndSwap(
        at path: DeviceRootPath,
        expectedRevisionUID: String?, bytes: Data
    ) async throws -> DeviceRootItem
    func putImmutable(
        at path: DeviceRootPath,
        expectedSHA256: String, bytes: Data
    ) async throws -> DeviceRootItem
    func trashOwn(item: DeviceRootItem) async throws
    func deleteOwnFromTrash(item: DeviceRootItem) async throws
    func restore(item: DeviceRootItem) async throws -> DeviceRootItem
}
