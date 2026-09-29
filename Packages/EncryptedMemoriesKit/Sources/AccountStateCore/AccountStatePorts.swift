import DeviceRootCore
import Foundation

/// What a sealed state file must belong to. A file sealed for another account, root incarnation, or state never opens.
public struct AccountStateBinding: Hashable, Sendable {
    /// A stable account identifier, never the identifier of one sign-in session.
    public let accountID: String
    public let rootIncarnation: String
    public let stateID: String

    public init(accountID: String, rootIncarnation: String, stateID: String) {
        self.accountID = accountID
        self.rootIncarnation = rootIncarnation
        self.stateID = stateID
    }
}

/// Why a sealed file cannot be trusted. Every reason keeps critical state closed.
public enum AccountStateRejection: Equatable, Sendable {
    case wrongBinding
    case badSignature
    case keyUnavailable
    case malformed
}

public enum AccountStateOpenResult: Equatable, Sendable {
    /// The document bytes, after decryption and signature verification.
    case opened(Data)
    /// A newer sealing format. This build neither opens nor replaces it.
    case newerFormat(Int)
    case rejected(AccountStateRejection)
}

/// App encryption and signatures on top of the storage encryption. Thrown errors mean the check could not run, for
/// example because the key service is unreachable; they never mean the file is bad.
public protocol AccountStateSealing: Sendable {
    func open(_ sealed: Data, binding: AccountStateBinding) async throws -> AccountStateOpenResult
    /// Seals a document. With `basedOn`, the new file reuses the key of that sealed file, so every device keeps
    /// reading data encrypted under it. Without it, the sealer creates the first key.
    func seal(_ document: Data, binding: AccountStateBinding, basedOn previous: Data?) async throws -> Data
}

/// The device's durable copy of the state. It is the only thing a write intent needs: the copy already contains
/// the change, and the document merges safely, so a repeated write never loses or duplicates a change.
public struct AccountStateLocalRecord: Equatable, Sendable {
    /// The account, root incarnation, and state this copy belongs to. A copy of another binding is never merged.
    public var binding: AccountStateBinding
    /// The canonical document bytes.
    public var document: Data
    /// The last sealed file this device read or wrote. The next seal reuses its key.
    public var lastSealed: Data?
    /// The state existed remotely at some point. A missing file is then a loss, not a first setup.
    public var published: Bool
    /// The copy holds changes that no confirmed remote revision contains yet.
    public var hasUnpublishedChanges: Bool

    public init(
        binding: AccountStateBinding, document: Data, lastSealed: Data?, published: Bool, hasUnpublishedChanges: Bool
    ) {
        self.binding = binding
        self.document = document
        self.lastSealed = lastSealed
        self.published = published
        self.hasUnpublishedChanges = hasUnpublishedChanges
    }
}

/// `save` returns only after the record is durable. A failure leaves the previous record in place.
public protocol AccountStateLocalStore: Sendable {
    func load() async throws -> AccountStateLocalRecord?
    func save(_ record: AccountStateLocalRecord) async throws
}
