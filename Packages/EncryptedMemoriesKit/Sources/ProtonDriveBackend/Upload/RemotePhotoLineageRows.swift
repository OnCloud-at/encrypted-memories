import UploadCore

struct RemotePhotoLineageRows {
    var identities: [UploadRemoteLinkIdentityRecord] = []
    var lineage: [UploadRemoteLineageRecord] = []
    var unresolvedLinkIDs: Set<String> = []

    init() {}

    init(attributes: DedupeXAttr, link: AlbumPhotoLinkBody, remoteLinkID: String, hashKeyEpoch: String) {
        guard link.type == nil || link.type == 2 else { return }
        if let state = link.state, state != 1 {
            if state != 0 && state != 2 { unresolvedLinkIDs.insert(remoteLinkID) }
            return
        }
        guard link.state == 1, let photo = link.fileProperties?.activeRevision?.photo else {
            unresolvedLinkIDs.insert(remoteLinkID)
            return
        }
        let isMain = photo.mainPhotoLinkID == nil
        if let identifier = attributes.iOSPhotos?.iCloudID, !identifier.isEmpty {
            identities.append(
                .init(
                    hashKeyEpoch: hashKeyEpoch, remoteLinkID: remoteLinkID,
                    externalIdentifier: identifier, isMain: isMain))
        }
        if attributes.unreadableLineageMarker { unresolvedLinkIDs.insert(remoteLinkID) }
        if isMain, let marker = attributes.lineage {
            lineage = marker.replaces.map {
                .init(hashKeyEpoch: hashKeyEpoch, replacedLinkID: $0, replacingLinkID: remoteLinkID)
            }
        }
    }

    mutating func merge(_ other: Self) {
        identities.append(contentsOf: other.identities)
        lineage.append(contentsOf: other.lineage)
        unresolvedLinkIDs.formUnion(other.unresolvedLinkIDs)
    }
}
