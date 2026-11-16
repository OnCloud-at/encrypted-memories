import Foundation
import PhotosCore
import UploadCore

/// Why the catalog sync stopped. Every case is a failure of the app's own stores: Photos and the network did not
/// fail. The person sees one localized local-state message for each case; `diagnosticText` is the technical wording
/// for the diagnostics only.
public enum PhotoLibraryCatalogSyncError: Error, Equatable, Sendable, CaseIterable, LocalizedError,
    FailureClassifiable
{
    case scanStateNotSaved
    case scanStateNotReset
    case scanStateUnavailable
    case scanSnapshotNotStarted
    case scanSnapshotNotSaved
    case scanSnapshotNotPublished
    case scanSnapshotUnavailable
    case scanSnapshotNotRead
    case scanSnapshotIncomplete
    case removalsNotSaved
    case scanProgressNotSaved
    case removalSweepNotSaved
    case scanNotCompleted
    case catalogUnavailable
    case catalogNotRead
    case catalogNotUpdated
    case catalogClassificationIncomplete
    /// The queue or the catalog cannot answer; the sync gives no further detail.
    case localStateUnavailable

    /// The localized message that a person sees for every failed scan. One place names its key.
    public static var localStateMessage: String { UploadError.InternalFailure.localStateMessage }

    /// The technical wording of the failure. Only the diagnostics read it; it never reaches a label.
    public var diagnosticText: String {
        switch self {
        case .scanStateNotSaved: "Photo library scan state could not be saved"
        case .scanStateNotReset: "Photo library scan state could not be reset"
        case .scanStateUnavailable: "Photo library scan state is unavailable"
        case .scanSnapshotNotStarted: "Photo library scan snapshot could not be started"
        case .scanSnapshotNotSaved: "Photo library scan snapshot could not be saved"
        case .scanSnapshotNotPublished: "Photo library scan snapshot could not be published"
        case .scanSnapshotUnavailable: "Photo library scan snapshot is unavailable"
        case .scanSnapshotNotRead: "Photo library scan snapshot could not be read"
        case .scanSnapshotIncomplete: "Photo library scan snapshot is incomplete"
        case .removalsNotSaved: "Photo library removals could not be saved"
        case .scanProgressNotSaved: "Photo library scan progress could not be saved"
        case .removalSweepNotSaved: "Photo library removal sweep could not be saved"
        case .scanNotCompleted: "Photo library scan could not be completed"
        case .catalogUnavailable: "Photo library catalog is unavailable"
        case .catalogNotRead: "Photo library catalog could not be read"
        case .catalogNotUpdated: "Photo library catalog could not be updated"
        case .catalogClassificationIncomplete: "Photo library catalog classification was incomplete"
        case .localStateUnavailable: Self.localStateMessage
        }
    }

    public var errorDescription: String? { Self.localStateMessage }

    public var failureCause: FailureCause { .localState }
}
