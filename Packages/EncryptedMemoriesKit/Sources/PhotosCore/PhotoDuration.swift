/// Converts a positive duration to whole seconds when it fits in an Int.
public enum PhotoDuration {
    public static func roundedSeconds(_ seconds: Double?) -> Int? {
        guard let seconds, seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return nil }
        return checkedInteger(seconds.rounded(), as: Int.self)
    }
}
