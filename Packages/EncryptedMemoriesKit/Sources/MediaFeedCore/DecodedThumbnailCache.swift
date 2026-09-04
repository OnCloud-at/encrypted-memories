import Foundation
import MediaDecodingCore
import PhotosCore

/// Thread-safe LRU cache keyed by photo ID and evicted by decoded byte count.
final class DecodedThumbnailCache: @unchecked Sendable {
    struct Metrics: Sendable, Equatable {
        let entryCount: Int
        let byteCost: Int
    }
    private final class Node {
        let uid: PhotoUID
        var image: DecodedThumbnail
        var cost: Int
        /// The requested decode limit, which can differ from the resulting image size.
        var decodePixelCap: Int
        var prev: Node?
        var next: Node?
        init(uid: PhotoUID, image: DecodedThumbnail, cost: Int, decodePixelCap: Int) {
            self.uid = uid
            self.image = image
            self.cost = cost
            self.decodePixelCap = decodePixelCap
        }
    }

    private let lock = NSLock()
    private var map: [PhotoUID: Node] = [:]
    private var head: Node?  // Most recently used.
    private var tail: Node?  // Least recently used and evicted first.
    private var totalCost = 0
    private var costLimit: Int

    init(costLimit: Int) {
        self.costLimit = max(1, costLimit)
    }

    /// Returns an image and promotes it to the front of the LRU list.
    func image(for uid: PhotoUID) -> DecodedThumbnail? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = map[uid] else { return nil }
        moveToFront(node)
        return node.image
    }

    /// Checks membership without changing the eviction order.
    func contains(_ uid: PhotoUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return map[uid] != nil
    }

    /// Returns whether an entry satisfies the requested decode size.
    func hasAdequateEntry(for uid: PhotoUID, requestedPixels: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let node = map[uid] else { return false }
        return !ThumbnailDecodeUpgradePolicy.needsSharperDecode(
            cachedDecodePixels: node.decodePixelCap, requestedPixels: requestedPixels)
    }

    /// Returns whether an existing entry needs a sharper decode.
    func needsSharperDecode(for uid: PhotoUID, requestedPixels: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let node = map[uid] else { return false }
        return ThumbnailDecodeUpgradePolicy.needsSharperDecode(
            cachedDecodePixels: node.decodePixelCap, requestedPixels: requestedPixels)
    }

    /// Stores the sharpest result and evicts older entries while retaining one oversized result.
    func set(_ image: DecodedThumbnail, for uid: PhotoUID, decodePixelCap: Int) {
        let cap = max(1, decodePixelCap)
        let cost = max(0, image.decodedCostBytes)
        lock.lock()
        defer { lock.unlock() }
        if let node = map[uid] {
            guard cap >= node.decodePixelCap else {
                moveToFront(node)
                return
            }
            totalCost += cost - node.cost
            node.image = image
            node.cost = cost
            node.decodePixelCap = cap
            moveToFront(node)
        } else {
            let node = Node(uid: uid, image: image, cost: cost, decodePixelCap: cap)
            map[uid] = node
            insertAtFront(node)
            totalCost += cost
        }
        evictToBudget(keeping: uid)
    }

    func setCostLimit(_ bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        costLimit = max(1, bytes)
        evictToBudget(keeping: nil)
    }

    func remove(_ uid: PhotoUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let node = map.removeValue(forKey: uid) else { return }
        unlink(node)
        totalCost -= node.cost
    }

    /// Drops only entries which no longer belong to the visible projection.
    /// Source refreshes preserve every still-valid decoded tile and avoid a full-grid re-decode.
    func retainOnly(_ allowedUIDs: Set<PhotoUID>) {
        lock.lock()
        defer { lock.unlock() }
        let removed = map.keys.filter { !allowedUIDs.contains($0) }
        for uid in removed {
            guard let node = map.removeValue(forKey: uid) else { continue }
            unlink(node)
            totalCost -= node.cost
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        map.removeAll(keepingCapacity: true)
        head = nil
        tail = nil
        totalCost = 0
    }

    func metrics() -> Metrics {
        lock.lock()
        defer { lock.unlock() }
        return Metrics(entryCount: map.count, byteCost: totalCost)
    }

    // MARK: - LRU List

    private func insertAtFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func unlink(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        insertAtFront(node)
    }

    private func evictToBudget(keeping uid: PhotoUID?) {
        while totalCost > costLimit, let victim = tail, victim.uid != uid {
            unlink(victim)
            map[victim.uid] = nil
            totalCost -= victim.cost
        }
    }

    #if DEBUG
        /// Returns the entry count and byte cost for cache tests.
        func snapshotForTesting() -> (count: Int, cost: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (map.count, totalCost)
        }
    #endif
}
