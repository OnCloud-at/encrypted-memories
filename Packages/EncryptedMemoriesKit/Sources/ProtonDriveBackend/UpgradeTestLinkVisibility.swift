#if ENCRYPTED_MEMORIES_UPGRADE_TEST
    import PhotosCore

    // This query became part of the backend contract after v1.0.5.
    extension UpgradeTestBackend {
        func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
            let active = Set(try await links().map(\.id))
            return Dictionary(
                uniqueKeysWithValues: linkIDs.map {
                    ($0, RemoteLinkVisibility(isActive: active.contains($0), mainPhotoLinkID: nil))
                })
        }
    }
#endif
