import Foundation

/// Stable consumable product identifiers for optional tips.
///
/// The universal app uses one product namespace on iOS, iPadOS, and macOS.
public enum TipJarProduct: String, CaseIterable, Sendable {
    case small
    case medium
    case large
    case extraLarge = "extra_large"

    public static func identifiers(bundleIdentifier: String) -> [String] {
        allCases.map { "\(bundleIdentifier).tip.\($0.rawValue)" }
    }

    public static func contains(_ productIdentifier: String, bundleIdentifier: String) -> Bool {
        identifiers(bundleIdentifier: bundleIdentifier).contains(productIdentifier)
    }
}
