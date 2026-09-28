import AppKit
import PhotosCore

/// Reads the photo references that the grid adds to every dragged photo (`PhotoFilePromiseProvider`).
///
/// A drop target inside the app reads them from the drag pasteboard itself. SwiftUI's `onDrop` hands each item of a
/// file-promise drag over as an `NSItemProvider` without any registered type, so the references never load there.
@MainActor public enum PhotoDragPasteboard {
    nonisolated static let referenceType = NSPasteboard.PasteboardType(PhotoDragReference.typeIdentifier)

    /// The drag sessions that a grid of this app runs right now. The system asks the drop target before it ends the
    /// source's session, so the current drag is still here while a drop reads it.
    private static var activeSessions: Set<UUID> = []

    static func beginSession(_ session: UUID) { activeSessions.insert(session) }
    static func endSession(_ session: UUID) { activeSessions.remove(session) }

    /// The photos of the grid's current drag on `pasteboard`, in drag order, and their drag sessions. Items without a
    /// valid photo reference, for example files from other apps, and references of an earlier or another app's drag
    /// are skipped.
    public static func references(on pasteboard: NSPasteboard) -> (uids: [PhotoUID], sessions: Set<UUID>) {
        references(on: pasteboard, activeSessions: activeSessions)
    }

    static func references(
        on pasteboard: NSPasteboard, activeSessions: Set<UUID>
    ) -> (uids: [PhotoUID], sessions: Set<UUID>) {
        var uids: [PhotoUID] = []
        var sessions: Set<UUID> = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let data = item.data(forType: referenceType),
                let reference = PhotoDragReference.decode(data),
                activeSessions.contains(reference.session)
            else { continue }
            uids.append(reference.uid)
            sessions.insert(reference.session)
        }
        return (uids, sessions)
    }
}
