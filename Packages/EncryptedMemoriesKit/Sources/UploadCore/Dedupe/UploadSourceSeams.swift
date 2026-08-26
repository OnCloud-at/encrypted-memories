import Foundation

// MARK: - Compounds

/// One logical photo as an upload unit with a primary resource and optional secondary resources.
public struct UploadCompoundDescriptor: Sendable {
    public let primary: UploadResourceDescriptor
    public let secondaries: [UploadResourceDescriptor]

    public init(primary: UploadResourceDescriptor, secondaries: [UploadResourceDescriptor] = []) {
        self.primary = primary
        self.secondaries = secondaries
    }
}

// MARK: - Platform source seam

/// A platform upload source enumerates compounds for the shared pipeline.
/// Adapters provide source resources; core owns identity, dedupe, and upload policy.
public protocol UploadCompoundSource: Sendable {
    /// The compounds this source currently offers, in upload order. Implementations should be
    /// lazy (PhotoKit enumerations are large) and honour task cancellation.
    func compounds() -> AsyncThrowingStream<UploadCompoundDescriptor, any Error>
}

// MARK: - Background checkpoint seam

/// Persists source completion so interrupted enumeration can resume without a full rescan.
public protocol UploadBackupCheckpointing: Sendable {
    /// Marks one source (asset/file) as fully handled - uploaded or confirmed duplicate.
    func markCompleted(_ source: UploadSourceIdentity) async
    /// True when the source was already handled by a previous run.
    func isCompleted(_ source: UploadSourceIdentity) async -> Bool
}
