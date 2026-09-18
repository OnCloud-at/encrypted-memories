import Foundation

public struct TimelineRefreshRetrySchedule: Sendable, Equatable {
    public let delays: [Duration]

    public init(delays: [Duration]) {
        self.delays = delays
    }

    /// Immediate refresh, then bounded eventual-consistency retries. Total wait: about 30 seconds.
    ///
    /// The early steps are short on purpose. A photo that the user just created locally - a manual upload, or
    /// a favorite kept from a series - is usually listed by the server within a second, and the old first
    /// retry of one second made the grid show it only after four seconds. The long tail stays for a server
    /// that needs much longer.
    public static let uploadDefault = TimelineRefreshRetrySchedule(
        delays: [
            .zero, .milliseconds(350), .milliseconds(650), .seconds(1), .seconds(2), .seconds(4),
            .seconds(8), .seconds(14),
        ]
    )
}
