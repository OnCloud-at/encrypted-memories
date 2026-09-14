/// Hysteresis for the automatic disk-cap pass: a real budget evicts slightly below its cap so a following
/// write burst does not re-enumerate the whole directory on every debounce window. Small budgets (tests,
/// tiny caches) keep exact-cap eviction.
public enum ThumbnailCacheDiskCapPolicy {
    static let hysteresisFloorBytes: Int64 = 64 * 1024 * 1024
    public static func evictionTarget(capBytes: Int64) -> Int64 {
        guard capBytes >= hysteresisFloorBytes else { return max(capBytes, 0) }
        return capBytes - min(capBytes / 16, hysteresisFloorBytes)
    }
}
