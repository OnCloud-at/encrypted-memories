import PhotosCore

public struct LibraryThumbnailResolutionSnapshot: Equatable, Sendable {
    public let availableUIDs: [PhotoUID]
    public let terminalUIDs: [PhotoUID]

    public init(availableUIDs: [PhotoUID] = [], terminalUIDs: [PhotoUID] = []) {
        self.availableUIDs = availableUIDs
        self.terminalUIDs = terminalUIDs
    }
}

public extension ThumbnailFeedCore {
    /// Checks a bounded new-asset batch and optionally re-enqueues only its missing thumbnails. Disk presence is
    /// sufficient: the grid decodes a resident thumbnail on demand, so this never retains extra decoded images.
    func libraryUpdateResolution(
        for uids: [PhotoUID],
        enqueueMissing: Bool
    ) async -> LibraryThumbnailResolutionSnapshot {
        var available: [PhotoUID] = []
        var terminal: [PhotoUID] = []
        available.reserveCapacity(uids.count)
        terminal.reserveCapacity(uids.count)

        for uid in uids {
            if memoryDecoded(for: uid) != nil {
                available.append(uid)
                continue
            }
            let cache = await cacheState(for: ThumbnailRequest(uid: uid))
            if cache.diskThumbnail {
                available.append(uid)
            } else if isKnownUnfetchable(uid) {
                terminal.append(uid)
            } else if enqueueMissing {
                _ = requestPriority(uid, priority: .zoomAnchorAndFocusRow)
            }
        }
        return LibraryThumbnailResolutionSnapshot(
            availableUIDs: available,
            terminalUIDs: terminal
        )
    }
}
