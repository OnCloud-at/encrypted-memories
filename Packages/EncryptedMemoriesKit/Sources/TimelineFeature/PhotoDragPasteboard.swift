import AppKit
import PhotosCore

/// Reads the photo references that the grid adds to every dragged photo (`PhotoFilePromiseProvider`).
///
/// A drop target inside the app reads them from the drag pasteboard itself. SwiftUI's `onDrop` hands each item of a
/// file-promise drag over as an `NSItemProvider` without any registered type, so the references never load there.
public enum PhotoDragPasteboard {
    static let referenceType = NSPasteboard.PasteboardType(PhotoDragReference.typeIdentifier)

    /// The photos on `pasteboard`, in drag order, and their drag sessions. Items without a valid photo reference, for
    /// example files from other apps, are skipped.
    public static func references(on pasteboard: NSPasteboard) -> (uids: [PhotoUID], sessions: Set<UUID>) {
        var uids: [PhotoUID] = []
        var sessions: Set<UUID> = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let data = item.data(forType: referenceType),
                let reference = PhotoDragReference.decode(data)
            else { continue }
            uids.append(reference.uid)
            sessions.insert(reference.session)
        }
        return (uids, sessions)
    }
}
