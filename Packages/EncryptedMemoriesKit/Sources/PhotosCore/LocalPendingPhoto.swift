import Foundation

/// A local photo that the backup will upload but that has no Proton identity yet.
///
/// Pending tiles use a reserved `PhotoUID` namespace so the grid, feed and viewer can treat them like any
/// other item. Every remote-only consumer (Smart Search, location crawl, source analysis, thumbnail crawl,
/// backend calls) must filter them out with `isLocalPending`.
public enum LocalPendingNamespace: String, Sendable, CaseIterable {
    /// An Apple Photos asset. The node ID is its `PHAsset.localIdentifier`.
    case photoLibrary = "local.photos"
    /// A file in a watched Mac folder. The node ID is its absolute path.
    case file = "local.files"
}

extension PhotoUID {
    public init(localPending namespace: LocalPendingNamespace, identifier: String) {
        self.init(volumeID: namespace.rawValue, nodeID: identifier)
    }

    public var localPendingNamespace: LocalPendingNamespace? {
        LocalPendingNamespace(rawValue: volumeID)
    }

    public var isLocalPending: Bool { localPendingNamespace != nil }
}

/// Splits a mixed selection into local pending photos and Proton photos, so every action sends each
/// identity to the owner that can act on it.
public struct LocalPendingSplit: Sendable, Equatable {
    public let local: [PhotoUID]
    public let remote: [PhotoUID]

    public init<S: Sequence>(_ uids: S) where S.Element == PhotoUID {
        var local: [PhotoUID] = []
        var remote: [PhotoUID] = []
        for uid in uids {
            if uid.isLocalPending { local.append(uid) } else { remote.append(uid) }
        }
        self.local = local
        self.remote = remote
    }
}
