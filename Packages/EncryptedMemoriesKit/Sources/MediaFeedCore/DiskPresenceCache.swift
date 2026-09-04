import Foundation
import PhotosCore

/// Tracks thumbnail availability for the active crawl by stable photo ID.
final class DiskPresenceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PhotoUID: Bool] = [:]
    private var trackedKeys: Set<PhotoUID> = []
    private var trackedTotal = 0
    private var trackedPresent = 0

    func beginTracking(
        _ uids: [PhotoUID],
        reporting reportingUIDs: Set<PhotoUID>? = nil,
        knownPresent: Set<PhotoUID> = []
    ) {
        lock.withLock {
            let allKeys = Set(uids)
            trackedKeys = reportingUIDs.map { $0.intersection(allKeys) } ?? allKeys
            trackedTotal = trackedKeys.count
            for uid in knownPresent where trackedKeys.contains(uid) {
                values[uid] = true
            }
            trackedPresent = trackedKeys.reduce(0) { count, uid in
                count + (values[uid] == true ? 1 : 0)
            }
        }
    }

    /// Clears all cached presence state after a cache reset or session change.
    func invalidate() {
        lock.withLock {
            values.removeAll(keepingCapacity: true)
            trackedKeys.removeAll(keepingCapacity: true)
            trackedTotal = 0
            trackedPresent = 0
        }
    }

    func set(_ uid: PhotoUID, present: Bool) {
        lock.withLock {
            let old = values[uid]
            values[uid] = present
            guard trackedKeys.contains(uid), old != present else { return }
            if present {
                trackedPresent += 1
            } else if old == true {
                trackedPresent = max(0, trackedPresent - 1)
            }
        }
    }

    func coverage() -> (present: Int, total: Int, percent: Double) {
        lock.withLock {
            guard trackedTotal > 0 else { return (0, 0, 1) }
            let present = min(trackedPresent, trackedTotal)
            return (present, trackedTotal, Double(present) / Double(trackedTotal))
        }
    }
}
