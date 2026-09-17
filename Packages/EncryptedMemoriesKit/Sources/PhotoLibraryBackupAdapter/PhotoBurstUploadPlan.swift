import Foundation

/// PhotoKit-free description of one photo of a burst (series). The mapper translates the `PHAsset`
/// burst properties into this; choosing the main photo and ordering the members is pure logic.
public struct PhotoBurstAssetDescriptor: Sendable, Equatable {
    public var info: PhotoBackupAssetInfo
    /// `PHAssetBurstSelectionType.userPick`: the user marked this photo as a favorite of the series.
    public var isUserPick: Bool
    /// `PHAsset.representsBurst`: the photo PhotoKit shows for the collapsed series.
    public var representsBurst: Bool

    public init(info: PhotoBackupAssetInfo, isUserPick: Bool, representsBurst: Bool) {
        self.info = info
        self.isUserPick = isUserPick
        self.representsBurst = representsBurst
    }
}

/// How one series uploads: one main photo plus its members as related photos of that main photo.
public struct PhotoBurstUploadPlan: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public var localIdentifier: String
        /// The role of the member's own resource that carries its current user-visible bytes.
        public var exportedRole: PhotoBackupAssetInfo.Resource.Role
        public var uploadFilename: String
        public var mimeType: String?
    }

    public var mainLocalIdentifier: String
    /// Ordered like the main photo's `.burstMember` resources: `members[n]` is ordinal `n`.
    public var members: [Member]
}

/// Pure series planning. No PhotoKit, no I/O.
///
/// PhotoKit's default fetch returns the representative photo and every user pick of a series, so one series
/// can surface as several assets. Exactly one of them owns the upload compound; the others carry
/// `.burstMainReference` and never upload on their own.
public enum PhotoBurstUploadPlanner {
    /// Nil when the series has fewer than two exportable photos; such an asset uploads as a plain photo.
    public static func plan(for assets: [PhotoBurstAssetDescriptor]) -> PhotoBurstUploadPlan? {
        let exportable = assets.compactMap { asset -> (PhotoBurstAssetDescriptor, PhotoBackupExportPlan.Item)? in
            guard let primary = PhotoBackupAssetPlanner.exportPlan(for: asset.info)?.primary else { return nil }
            return (asset, primary)
        }
        .sorted { lhs, rhs in captureOrder(lhs.0.info, rhs.0.info) }
        guard exportable.count > 1 else { return nil }

        // The user's pick is the main photo, as in Apple Photos; the representative is the fallback.
        let main =
            exportable.first { $0.0.isUserPick }
            ?? exportable.first { $0.0.representsBurst }
            ?? exportable[0]
        let mainIdentifier = main.0.info.localIdentifier

        var seenNames: Set<String> = []
        let members =
            exportable
            .filter { $0.0.info.localIdentifier != mainIdentifier }
            .map { asset, primary in
                PhotoBurstUploadPlan.Member(
                    localIdentifier: asset.info.localIdentifier,
                    exportedRole: primary.role,
                    uploadFilename: uniqueFilename(primary.uploadFilename, seen: &seenNames),
                    mimeType: primary.mimeType
                )
            }
            .sorted { lhs, rhs in
                // The same order `PhotoBackupAssetPlanner` assigns resource ordinals in. Unique filenames make
                // it total, so an ordinal always names the same member.
                lhs.uploadFilename.localizedStandardCompare(rhs.uploadFilename) == .orderedAscending
            }
        return PhotoBurstUploadPlan(mainLocalIdentifier: mainIdentifier, members: members)
    }

    /// Projects the plan onto one asset of the series. The main photo gains one `.burstMember` resource per
    /// member; every other photo gains a `.burstMainReference`, which removes it from standalone backup.
    public static func applying(
        _ plan: PhotoBurstUploadPlan,
        to info: PhotoBackupAssetInfo
    ) -> PhotoBackupAssetInfo {
        var copy = info
        if info.localIdentifier == plan.mainLocalIdentifier {
            copy.resources += plan.members.map {
                PhotoBackupAssetInfo.Resource(
                    role: .burstMember,
                    originalFilename: $0.uploadFilename,
                    mimeType: $0.mimeType
                )
            }
        } else {
            copy.resources.append(
                PhotoBackupAssetInfo.Resource(role: .burstMainReference, originalFilename: plan.mainLocalIdentifier)
            )
        }
        return copy
    }

    private static func captureOrder(_ lhs: PhotoBackupAssetInfo, _ rhs: PhotoBackupAssetInfo) -> Bool {
        let left = lhs.creationDate ?? .distantPast
        let right = rhs.creationDate ?? .distantPast
        if left != right { return left < right }
        return lhs.localIdentifier < rhs.localIdentifier
    }

    private static func uniqueFilename(_ filename: String, seen: inout Set<String>) -> String {
        if seen.insert(filename.lowercased()).inserted { return filename }
        let name = filename as NSString
        let base = name.deletingPathExtension
        let ext = name.pathExtension
        var suffix = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            if seen.insert(candidate.lowercased()).inserted { return candidate }
            suffix += 1
        }
    }
}
