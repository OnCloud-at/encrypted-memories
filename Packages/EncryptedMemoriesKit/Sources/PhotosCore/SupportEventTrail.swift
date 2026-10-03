import Foundation

/// A bounded trail of recent events for the support report. Every field is a closed set of values or a count;
/// the subject identifier stays in memory and leaves the device only as a per-report salted hash, so a report can
/// follow one photo through its events without revealing which photo it is. Nothing is written to disk.
public final class SupportEventTrail: @unchecked Sendable {
    public static let shared = SupportEventTrail()

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case libraryLoadSucceeded, libraryLoadFailed
        case backupRowCompleted, backupRowAlreadyBackedUp, backupRowWaiting, backupRowParked, backupRowSkipped
        case backupRowNeedsReconciliation
        case editReplaced, editKept, editWaiting, editReplacementGone
    }

    struct Event: Sendable, Equatable {
        let time: Date
        let kind: Kind
        let subject: String?
        let resourceKind: BackupQueueSupportSnapshot.ResourceKind?
        let reason: BackupQueueSupportSnapshot.Reason?
        let sourcePath: LibrarySyncSupportSnapshot.SourcePath?
        let errorKind: LibrarySyncSupportSnapshot.ErrorKind?
        let count: Int?
    }

    /// One exported event. `subject` is the salted hash of the in-memory identifier.
    public struct ExportedEvent: Codable, Sendable, Equatable {
        public let time: Date
        public let kind: Kind
        public let subject: String?
        public let resourceKind: BackupQueueSupportSnapshot.ResourceKind?
        public let reason: BackupQueueSupportSnapshot.Reason?
        public let sourcePath: LibrarySyncSupportSnapshot.SourcePath?
        public let errorKind: LibrarySyncSupportSnapshot.ErrorKind?
        public let count: Int?
    }

    public static let defaultCapacity = 400

    private let lock = NSLock()
    private let capacity: Int
    /// A ring: `next` is the slot that the next event overwrites once the ring is full.
    private var events: [Event] = []
    private var next = 0
    private var dropped = 0
    private let now: @Sendable () -> Date

    public init(capacity: Int = SupportEventTrail.defaultCapacity, now: @Sendable @escaping () -> Date = { Date() }) {
        self.capacity = max(1, capacity)
        self.now = now
    }

    public func record(
        _ kind: Kind, subject: String? = nil, resourceKind: BackupQueueSupportSnapshot.ResourceKind? = nil,
        reason: BackupQueueSupportSnapshot.Reason? = nil, sourcePath: LibrarySyncSupportSnapshot.SourcePath? = nil,
        errorKind: LibrarySyncSupportSnapshot.ErrorKind? = nil, count: Int? = nil
    ) {
        let event = Event(
            time: now(), kind: kind, subject: subject, resourceKind: resourceKind, reason: reason,
            sourcePath: sourcePath, errorKind: errorKind, count: count)
        lock.withLock {
            if events.count < capacity {
                events.append(event)
            } else {
                events[next] = event
                next = (next + 1) % capacity
                dropped += 1
            }
        }
    }

    /// Account teardown clears the trail, so no identifier of a signed-out account stays in memory.
    public func clear() {
        lock.withLock {
            events.removeAll()
            next = 0
            dropped = 0
        }
    }

    public func export(hashingWith hasher: SupportReportIdentifierHasher) -> (events: [ExportedEvent], dropped: Int) {
        let (events, dropped) = lock.withLock { (Array(self.events[next...] + self.events[..<next]), self.dropped) }
        return (
            events.map {
                ExportedEvent(
                    time: $0.time, kind: $0.kind, subject: $0.subject.map(hasher.hash), resourceKind: $0.resourceKind,
                    reason: $0.reason, sourcePath: $0.sourcePath, errorKind: $0.errorKind, count: $0.count)
            }, dropped
        )
    }
}
