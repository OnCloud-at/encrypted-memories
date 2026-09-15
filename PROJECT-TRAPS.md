# Project traps

Hard constraints from known first-attempt failures. Read before changing code.

- Never route a shared-with-me album into the HTTP album writes (`AlbumsRepository.addPhotos/removePhotos/setAlbumCover/deleteAlbum`, `ProtonAlbumWriteService`, `DriveSDKBridge.setAlbumCover/deleteAlbum/removePhotos`), and never enable editor/admin writes from the SDK role alone. Why: these writes take a bare `AlbumID` and resolve the account's own Photos share, volume and root key (`resolveRootMaterial`, `resolveAlbumMaterial`, `resolvePhotosRoot`), so a foreign-volume album cannot be addressed; a local 2xx is not proof of shared-album support. Keep `AlbumCapabilities.canWriteSharedAlbums == false` until a volume-qualified, authenticated-runtime-verified transport exists. Files: `Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/Albums/ProtonAlbumWriteService.swift`, `Packages/EncryptedMemoriesKit/Sources/AlbumCore/AlbumsRepository.swift`.
