import PhotosCore
import XCTest

@testable import UploadCore

/// The SQLite connection of a store, read through reflection, so a fixture can act on the store's own connection.
/// Pass the store itself: an implicitly unwrapped property passed as `Any` reflects as an Optional and has no
/// `connection` child.
func storeConnection(_ store: Any) throws -> SQLiteStoreConnection {
    try XCTUnwrap(
        Mirror(reflecting: store).children.first(where: { $0.label == "connection" })?.value as? SQLiteStoreConnection)
}

/// Pending-grid effects that succeed without doing anything.
struct InertPendingEffects: PendingBackupEffects {
    func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool { true }
    func returnToBackup(_ keys: [PendingSourceKey]) async -> Bool { true }
    func photosVolumeID() async -> String? { "volume" }
    func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func restoreRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
}
