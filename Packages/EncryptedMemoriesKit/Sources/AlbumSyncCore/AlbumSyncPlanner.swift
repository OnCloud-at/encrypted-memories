import Foundation

/// The attach plan for one album sync run, computed after the backup step settled.
public struct AlbumSyncAttachPlan: Sendable, Equatable {
    /// Photos to attach, in local album order, deduplicated by remote link id.
    public var toAttach: [AlbumSyncAttachCandidate] = []
    /// Local assets whose remote photo is already in the album (no-op on re-run).
    public var alreadyMember = 0
    /// Local assets with no usable remote link (backup failed / asset missing) - honest gap.
    public var missingRemote = 0
    /// Local assets whose only remote copy sits in Proton trash - never attached, never re-uploaded.
    public var trashedRemote = 0
    /// The local identifiers behind `missingRemote`, in local album order.
    public var missingRemoteIdentifiers: [String] = []
    /// The local identifiers behind `trashedRemote`, in local album order.
    public var trashedRemoteIdentifiers: [String] = []
    /// Distinct local assets that resolved to an already-planned remote link or to a link with the same bytes
    /// (duplicate content across the album collapses to one attach).
    public var duplicatesCollapsed = 0

    public init() {}
}

/// Pure set-difference planning for local assets, manifest links, and current album members.
/// The result is deterministic, performs no I/O, and runs in linear time.
public enum AlbumSyncPlanner {
    /// - Parameter memberWithSameContent: For a SHA-1, a current album member with the same bytes under another
    ///   link, for example another device's copy of a shared photo. Such a photo counts as already in the album.
    public static func plan(
        orderedLocalIdentifiers: [String],
        remoteLinks: [String: AlbumSyncRemoteLink],
        existingChildLinkIDs: Set<String>,
        memberWithSameContent: [String: String] = [:]
    ) -> AlbumSyncAttachPlan {
        var plan = AlbumSyncAttachPlan()
        var planned = Set<String>()
        planned.reserveCapacity(orderedLocalIdentifiers.count)
        var plannedContent = Set<String>()
        var seenMembers = Set<String>()

        for identifier in orderedLocalIdentifiers {
            guard let link = remoteLinks[identifier] else {
                plan.missingRemote += 1
                plan.missingRemoteIdentifiers.append(identifier)
                continue
            }
            if link.isTrashed {
                plan.trashedRemote += 1
                plan.trashedRemoteIdentifiers.append(identifier)
                continue
            }
            let linkID = link.uid.nodeID
            let member =
                existingChildLinkIDs.contains(linkID) ? linkID : link.sha1Hex.flatMap { memberWithSameContent[$0] }
            if let member {
                // Count each distinct member once even if several local assets map to it.
                if seenMembers.insert(member).inserted {
                    plan.alreadyMember += 1
                } else {
                    plan.duplicatesCollapsed += 1
                }
                continue
            }
            // A link with bytes that another planned link already carries would add the same photo twice.
            let newContent = link.sha1Hex.map { plannedContent.insert($0).inserted } ?? true
            if planned.insert(linkID).inserted, newContent {
                plan.toAttach.append(AlbumSyncAttachCandidate(uid: link.uid, sha1Hex: link.sha1Hex))
            } else {
                plan.duplicatesCollapsed += 1
            }
        }
        return plan
    }
}
