import Foundation

/// Formats quota bytes using Proton's 1024-based GB and TB units.
public enum ProtonStorageQuotaFormatter {
    public struct Presentation: Equatable, Sendable {
        public let used: String
        public let maximum: String
    }

    private static let gibibyte = Int64(1_073_741_824)
    private static let tebibyte = Int64(1_099_511_627_776)

    public static func presentation(
        usedBytes: Int64,
        maximumBytes: Int64,
        locale: Locale = .current
    ) -> Presentation {
        let usesTerabytes = maximumBytes >= tebibyte
        let divisor = Double(usesTerabytes ? tebibyte : gibibyte)
        let unit = usesTerabytes ? "TB" : "GB"

        return Presentation(
            used: format(
                Double(usedBytes) / divisor,
                unit: unit,
                minimumFractionDigits: 2,
                maximumFractionDigits: 2,
                locale: locale
            ),
            maximum: format(
                Double(maximumBytes) / divisor,
                unit: unit,
                minimumFractionDigits: 0,
                maximumFractionDigits: 1,
                locale: locale
            )
        )
    }

    private static func format(
        _ value: Double,
        unit: String,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int,
        locale: Locale
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.roundingMode = .halfUp
        let number = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return "\(number) \(unit)"
    }
}
