import Foundation

/// Parses internet date-time strings with or without fractional seconds.
/// Each instance reuses its fractional and whole-second formatters for every call.
package struct InternetDateParser {
    private let fractional = ISO8601DateFormatter()
    private let standard = ISO8601DateFormatter()

    package init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        standard.formatOptions = [.withInternetDateTime]
    }

    package func date(from raw: String) -> Date? {
        fractional.date(from: raw) ?? standard.date(from: raw)
    }
}
