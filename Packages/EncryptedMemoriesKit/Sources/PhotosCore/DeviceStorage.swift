import Foundation

/// The one free-space query of the app. It reports space for work the person asked for, so purgeable
/// system data counts as free.
public enum DeviceStorage {
    public static func availableCapacity(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

/// How full the device is. Optional caches stop growing at `low`; at `critical` they are cleared and
/// automatic work that writes large data pauses.
public enum LibraryStoragePressure: Int, Sendable, Equatable {
    case normal
    case low
    case critical

    private static let lowThreshold: Int64 = 2 << 30
    private static let criticalThreshold: Int64 = 512 << 20
    private static let recoveryMargin: Int64 = 256 << 20

    /// A level is left only after a margin above its threshold, so a device near a threshold does not flap.
    /// An unknown capacity keeps the previous level.
    public static func next(after previous: Self, availableBytes: Int64?) -> Self {
        guard let availableBytes else { return previous }
        if availableBytes < criticalThreshold { return .critical }
        if previous == .critical, availableBytes < criticalThreshold + recoveryMargin { return .critical }
        if availableBytes < lowThreshold { return .low }
        if previous != .normal, availableBytes < lowThreshold + recoveryMargin { return .low }
        return .normal
    }

    public func permitsDiskWrite(for cache: LibraryDiskCacheKind) -> Bool {
        switch self {
        case .normal: true
        case .low: cache == .thumbnail
        case .critical: false
        }
    }
}

/// Disk caches by importance. Grid thumbnails are the only cache the library needs to stay usable.
public enum LibraryDiskCacheKind: Sendable, Equatable {
    case thumbnail
    case preview
    case original
    case video

    public var evictsOnCritical: Bool { self != .thumbnail }
}
