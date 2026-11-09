/// The answer of a decision read of one key in local storage (#1140). A decision read is a read whose answer changes
/// what the app writes, deletes, uploads, retries, or shows as a result.
///
/// The answer is not Optional and does not throw, so a caller cannot apply `try?` or `?? default` to it. The read
/// that produces it must still report a failure itself: `init(catching:)` needs the throwing read in its closure,
/// because `StoreLookup(catching: { try? read() })` turns a failed read into `absent`.
public enum StoreLookup<Value> {
    /// The read ran to the end and returned the stored value.
    case found(Value)
    /// The read ran to the end and proved that no value is stored.
    case absent
    /// The read failed, or the stored value is unreadable. The caller must never treat this as `absent`: nothing is
    /// known about the stored value.
    case unknown

    /// Wraps a strict reader: a value is `found`, nil is `absent`, and every thrown error is `unknown`. A
    /// `CancellationError` is `unknown` too, because a cancelled read proves nothing about the stored value.
    public init(catching read: () throws -> Value?) {
        do {
            guard let value = try read() else {
                self = .absent
                return
            }
            self = .found(value)
        } catch {
            self = .unknown
        }
    }
}

extension StoreLookup: Sendable where Value: Sendable {}
extension StoreLookup: Equatable where Value: Equatable {}
