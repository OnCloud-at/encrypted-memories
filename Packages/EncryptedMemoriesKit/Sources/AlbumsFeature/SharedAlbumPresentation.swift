import AlbumCore
import Foundation
import PhotosCore

/// Localized row copy for one shared album. macOS and iOS use the same text and choose only the
/// native container, so role wording and read-only reasons cannot drift between platforms.
public struct SharedAlbumPresentation: Sendable, Equatable {
    /// Effective role title. Inherited access is never described as a direct invitation.
    public let roleTitle: String
    /// Compact secondary line: role, owner, photo count and link-share state.
    public let detailLine: String
    /// Inviter and invitation date, when present. Unverified inviters are marked as unverified.
    public let invitationDetail: String?
    /// Why the album cannot be edited here. Nil when a write is permitted.
    public let writeRestrictionReason: String?
    public let accessibilityLabel: String
    public let accessibilityHint: String?

    public init(album: SharedAlbumSummary, permissions: SharedAlbumPermissions) {
        let roleTitle = Self.roleTitle(album.role)
        let roleText =
            permissions.writeRestriction == .transportUnsupported
            ? L10n.string("albums.shared_role_read_only \(roleTitle)")
            : roleTitle

        var parts = [roleText]
        if let owner = album.owner, !owner.isEmpty {
            parts.append(L10n.string("albums.shared_owner \(owner)"))
        }
        parts.append(L10n.string("albums.photo_count \(album.photoCount)"))
        if album.isSharedByURL {
            parts.append(L10n.string("albums.shared_via_link"))
        }

        var invitationParts: [String] = []
        // Inherited access is never described with invitation details, even if the SDK sends both.
        if let invitation = album.invitation, album.role != .inherited {
            if let sharedBy = invitation.sharedBy {
                invitationParts.append(
                    invitation.isSharedByVerified
                        ? L10n.string("albums.shared_invited_by \(sharedBy)")
                        : L10n.string("albums.shared_invited_by_unverified \(sharedBy)")
                )
            } else if !invitation.isSharedByVerified {
                invitationParts.append(L10n.string("albums.shared_inviter_unverified"))
            }
            if let inviteTime = invitation.inviteTime {
                let date = inviteTime.formatted(date: .abbreviated, time: .omitted)
                invitationParts.append(L10n.string("albums.shared_invited_on \(date)"))
            }
        }

        let restriction = permissions.writeRestriction?.localizedReason
        let invitationDetail = invitationParts.isEmpty ? nil : invitationParts.joined(separator: " • ")
        let hint = [invitationDetail, restriction].compactMap { $0 }.joined(separator: ". ")

        self.roleTitle = roleTitle
        self.detailLine = parts.joined(separator: " • ")
        self.invitationDetail = invitationDetail
        self.writeRestrictionReason = restriction
        self.accessibilityLabel = "\(album.title), \(parts.joined(separator: ", "))"
        self.accessibilityHint = hint.isEmpty ? nil : hint
    }

    public static func roleTitle(_ role: SharedAlbumRole) -> String {
        switch role {
        case .inherited: L10n.string("albums.shared_role_inherited")
        case .viewer: L10n.string("albums.shared_role_viewer")
        case .editor: L10n.string("albums.shared_role_editor")
        case .admin: L10n.string("albums.shared_role_admin")
        }
    }
}
