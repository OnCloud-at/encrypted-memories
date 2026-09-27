import Foundation

/// The photo reference that the Mac grid adds to every dragged photo, so a drop inside the app (for example on an
/// album in the sidebar) adds the photo instead of copying its file. Other apps ignore this type; they receive the
/// file promise only.
public enum PhotoDragReference {
    /// Declared in the Mac app's Info.plist as an exported type.
    public static let typeIdentifier = "at.oncloud.encryptedmemories.photo-reference"

    /// Posted after a drop inside the app took references. The grid then stops preparing files for other apps, but
    /// only for the drag sessions named in the notification, so an earlier export to Finder still completes.
    public static let internalDropCompleted = Notification.Name("EncryptedMemories.photoDragInternalDropCompleted")

    private static let sessionsKey = "sessions"

    private struct Payload: Codable {
        let volumeID: String
        let nodeID: String
        let session: UUID
    }

    public static func data(for uid: PhotoUID, session: UUID) -> Data {
        // Encoding two strings and a UUID cannot fail.
        (try? JSONEncoder().encode(Payload(volumeID: uid.volumeID, nodeID: uid.nodeID, session: session))) ?? Data()
    }

    /// The photo and its drag session in `data`, or nil for anything else.
    public static func decode(_ data: Data) -> (uid: PhotoUID, session: UUID)? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
            !payload.volumeID.isEmpty, !payload.nodeID.isEmpty
        else { return nil }
        return (PhotoUID(volumeID: payload.volumeID, nodeID: payload.nodeID), payload.session)
    }

    public static func postInternalDrop(sessions: Set<UUID>) {
        NotificationCenter.default.post(
            name: internalDropCompleted, object: nil, userInfo: [sessionsKey: sessions])
    }

    public static func sessions(in notification: Notification) -> Set<UUID> {
        notification.userInfo?[sessionsKey] as? Set<UUID> ?? []
    }
}
