import Foundation
import PhotosCore

@testable import UploadCore

// Short reads for assertions. Each one goes through the production read that the app uses.

extension ExactDuplicateFingerprint {
    /// The details of a photo or video in the tests of possibly identical photos: one camera, 4000 x 3000 pixels, no
    /// place, and the capture second 1,700,000,000 plus `second`, unless a test says otherwise.
    static func possiblePhoto(
        type: String = "image/jpeg", camera: String? = "Camera", width: Int? = 4000, height: Int? = 3000,
        latitude: Double? = nil, longitude: Double? = nil, duration: Double? = nil, second: TimeInterval = 0
    ) -> ExactDuplicateFingerprint {
        ExactDuplicateFingerprint(
            captureTime: Date(timeIntervalSince1970: 1_700_000_000 + second), latitude: latitude, longitude: longitude,
            device: camera, pixelWidth: width, pixelHeight: height, durationSeconds: duration, mimeType: type)
    }
}

extension ExactDuplicateFingerprintStore {
    /// The saved details of `members` through the group read of the Duplicates screen. Nil when one member has none.
    func fingerprints(for members: [PhotoUID], in snapshot: Snapshot) -> [PhotoUID: ExactDuplicateFingerprint]? {
        guard !members.isEmpty else { return [:] }
        let group = ExactDuplicateGroup(contentHash: "", hashKeyEpoch: snapshot.scope.hashKeyEpoch, members: members)
        let saved = fingerprints(ofGroups: [group], in: snapshot)
        return saved.isEmpty ? nil : saved
    }
}

extension ExactDuplicateFinder {
    /// The members of each group by group ID, the photo to keep first, from all pages of `rankMembers`.
    func rankedMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
        let collected = RankedPages()
        await rankMembers(of: groups) { await collected.add($0.members) }
        return await collected.members
    }
}

private actor RankedPages {
    private(set) var members: [String: [PhotoUID]] = [:]

    func add(_ page: [String: [PhotoUID]]) {
        members.merge(page) { _, new in new }
    }
}

extension UploadIdentityStore {
    /// One row of `trustedRecords`.
    func trustedRecord(contentHash: String, hashKeyEpoch: String) -> UploadIdentityRecord? {
        trustedRecords(contentHash: contentHash, hashKeyEpoch: hashKeyEpoch, limit: 1).first
    }
}

extension UploadRemoteContentIndexStore {
    /// One record of `remoteContentRecords`.
    func remoteContentRecord(contentHash: String, hashKeyEpoch: String) -> UploadRemoteContentIndexRecord? {
        remoteContentRecords(contentHash: contentHash, hashKeyEpoch: hashKeyEpoch, limit: 1).first
    }
}
