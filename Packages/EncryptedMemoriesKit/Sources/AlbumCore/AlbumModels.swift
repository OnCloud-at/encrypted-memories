import Foundation
import PhotosCore

// MARK: - Identifiers

/// A Proton photo album identifier (the album's link id within its volume).
public typealias AlbumID = String

// MARK: - Models

/// Lightweight album description for listing/selection UIs.
public struct AlbumSummary: Identifiable, Sendable, Equatable {
    public let id: AlbumID
    /// The SDK node's volume. Writes still use `id` because owned Photos albums share the account's
    /// Photos volume; retaining the volume here keeps catalog identity lossless.
    public let volumeID: String?
    public let title: String
    public let photoCount: Int
    /// The link id of the photo currently used as the album cover, if any.
    public let coverPhotoID: String?
    public let coverPhotoUID: PhotoUID?
    public let lastActivityTime: Date?
    public let isShared: Bool
    public let isSharedByURL: Bool
    /// True when the SDK returned the node but one or more encrypted metadata fields could not be
    /// verified/decrypted. The album remains addressable; presentation can avoid claiming complete metadata.
    public let isMetadataDegraded: Bool

    public init(
        id: AlbumID,
        volumeID: String? = nil,
        title: String,
        photoCount: Int,
        coverPhotoID: String?,
        coverPhotoUID: PhotoUID? = nil,
        lastActivityTime: Date? = nil,
        isShared: Bool = false,
        isSharedByURL: Bool = false,
        isMetadataDegraded: Bool = false
    ) {
        self.id = id
        self.volumeID = volumeID
        self.title = title
        self.photoCount = photoCount
        self.coverPhotoID = coverPhotoID
        self.coverPhotoUID =
            coverPhotoUID
            ?? volumeID.flatMap { volumeID in
                coverPhotoID.map { PhotoUID(volumeID: volumeID, nodeID: $0) }
            }
        self.lastActivityTime = lastActivityTime
        self.isShared = isShared
        self.isSharedByURL = isSharedByURL
        self.isMetadataDegraded = isMetadataDegraded
    }
}

/// Lossless SDK identity for an album or photo node. Album membership and shared-with-me data may
/// cross volumes, so a bare link id is not sufficient outside owned-album write endpoints.
public struct AlbumNodeIdentifier: Hashable, Sendable, Codable {
    public let volumeID: String
    public let nodeID: String

    public init(volumeID: String, nodeID: String) {
        self.volumeID = volumeID
        self.nodeID = nodeID
    }
}

/// A read-only album shared with the current account.
public struct SharedAlbumSummary: Identifiable, Sendable, Equatable {
    public var id: AlbumNodeIdentifier { node }
    public let node: AlbumNodeIdentifier
    public let title: String
    public let photoCount: Int
    public let coverPhotoID: String?
    public let coverPhotoUID: PhotoUID?
    public let owner: String?
    public let lastActivityTime: Date?
    public let isSharedByURL: Bool
    public let isMetadataDegraded: Bool

    public init(
        node: AlbumNodeIdentifier,
        title: String,
        photoCount: Int,
        coverPhotoID: String?,
        coverPhotoUID: PhotoUID? = nil,
        owner: String?,
        lastActivityTime: Date?,
        isSharedByURL: Bool,
        isMetadataDegraded: Bool
    ) {
        self.node = node
        self.title = title
        self.photoCount = photoCount
        self.coverPhotoID = coverPhotoID
        self.coverPhotoUID =
            coverPhotoUID
            ?? coverPhotoID.map {
                PhotoUID(volumeID: node.volumeID, nodeID: $0)
            }
        self.owner = owner
        self.lastActivityTime = lastActivityTime
        self.isSharedByURL = isSharedByURL
        self.isMetadataDegraded = isMetadataDegraded
    }
}

public enum AlbumMembershipState: Sendable, Equatable {
    case none
    case some
    case all
}

// MARK: - Capabilities

/// Which album operations the wired backend can actually perform. Drives UI gating and honest
/// "unsupported" messaging; nothing is faked.
public struct AlbumCapabilities: Sendable, Equatable {
    public var canList: Bool
    public var canCreate: Bool
    public var canDelete: Bool
    public var canAddPhotos: Bool
    public var canRemovePhotos: Bool
    public var canSetCover: Bool
    public var canListSharedWithMe: Bool
    public var canLeaveSharedAlbum: Bool
    public var canReadMemberships: Bool

    public init(
        canList: Bool,
        canCreate: Bool,
        canDelete: Bool = false,
        canAddPhotos: Bool,
        canRemovePhotos: Bool = false,
        canSetCover: Bool,
        canListSharedWithMe: Bool = false,
        canLeaveSharedAlbum: Bool = false,
        canReadMemberships: Bool = false
    ) {
        self.canList = canList
        self.canCreate = canCreate
        self.canDelete = canDelete
        self.canAddPhotos = canAddPhotos
        self.canRemovePhotos = canRemovePhotos
        self.canSetCover = canSetCover
        self.canListSharedWithMe = canListSharedWithMe
        self.canLeaveSharedAlbum = canLeaveSharedAlbum
        self.canReadMemberships = canReadMemberships
    }

    /// Read-only: list works, writes are not supported.
    public static let readOnly = AlbumCapabilities(
        canList: true,
        canCreate: false,
        canDelete: false,
        canAddPhotos: false,
        canRemovePhotos: false,
        canSetCover: false
    )

    /// SDK 0.22 catalog without the app's direct-HTTP write adapter.
    public static let sdkReadOnlyCatalog = AlbumCapabilities(
        canList: true,
        canCreate: false,
        canDelete: false,
        canAddPhotos: false,
        canRemovePhotos: false,
        canSetCover: false,
        canListSharedWithMe: true,
        canLeaveSharedAlbum: true,
        canReadMemberships: true
    )

    /// SDK reads plus the narrow direct-HTTP write surface that SDK 0.25.0 cannot replace.
    public static let sdkCatalogWithHTTPWrites = AlbumCapabilities(
        canList: true,
        canCreate: true,
        canDelete: true,
        canAddPhotos: true,
        canRemovePhotos: true,
        canSetCover: true,
        canListSharedWithMe: true,
        canLeaveSharedAlbum: true,
        canReadMemberships: true
    )
}

// MARK: - Errors

/// Surfaced when an album operation cannot be completed. `.unsupported` is the explicit,
/// user-visible signal for "the wired backend cannot honestly perform this operation" - never a
/// crash, never silently downgraded to a library-only upload.
public enum AlbumError: LocalizedError, Equatable {
    /// The operation is not implemented by the wired backend. `operation`/`gap` are developer-facing
    /// diagnostics and are deliberately not surfaced in `errorDescription`.
    case unsupported(operation: String, gap: String)
    /// The album exists, but attaching the requested existing photos did not fully converge. The
    /// identifier is retained so UI can refresh the album list and offer a membership-only retry
    /// without creating a duplicate album.
    case albumCreatedButPhotosNotAdded(albumID: AlbumID, albumName: String, message: String)
    /// Proton accepted some membership writes and rejected others. Existing successful membership
    /// must never be hidden behind an all-or-nothing UI claim.
    case partialAdd(succeeded: Int, total: Int, message: String)
    case backend(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            L10n.string("error.album_action_unavailable")
        case .albumCreatedButPhotosNotAdded(_, let albumName, _):
            L10n.string("error.album_created_add_failed \(albumName)")
        case .partialAdd(let succeeded, let total, _):
            L10n.string("error.album_partial_add \(succeeded) \(total)")
        case .backend:
            L10n.string("error.album_backend")
        }
    }

    /// Raw backend context is retained for opt-in local diagnostics but is never presented to the user.
    /// Proton's API messages are not localized and may contain implementation detail or misleading client copy.
    public var diagnosticDescription: String {
        switch self {
        case .unsupported(let operation, let gap):
            "\(operation): \(gap)"
        case .albumCreatedButPhotosNotAdded(_, _, let message),
            .partialAdd(_, _, let message),
            .backend(let message):
            message
        }
    }
}
