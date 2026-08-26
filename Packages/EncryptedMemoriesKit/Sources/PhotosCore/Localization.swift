import Foundation

/// Resolves package-local String Catalog keys through `Bundle.module`.
///
/// Use this facade for package UI so lookups do not fall back to `Bundle.main`.
public enum L10n {
    /// Resolves `key` (a stable catalog key, optionally with interpolated arguments) against the
    /// package String Catalog. Interpolated values become `%@`/`%lld` format arguments and drive
    /// plural selection where the catalog entry defines plural variations.
    ///
    /// - Parameters:
    ///   - key: A `String.LocalizationValue` built from a stable catalog key. Interpolation is allowed
    ///          (`"key \(value)"`) and is captured as format arguments.
    ///   - comment: Optional translator note. Catalog comments are authored in the `.xcstrings` file,
    ///              so this is rarely needed at the call site.
    /// - Returns: The localized string for the app's effective language, falling back to English.
    public static func string(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String {
        String(localized: key, bundle: .module, comment: comment)
    }

    /// Resolves an app-reviewed catalog key selected from runtime metadata.
    public static func string(dynamicKey key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }

    /// Shared selection-toolbar copy so every native shell uses the same pluralization and prompt.
    public static func selectionCenterText(selectedCount: Int) -> String {
        switch max(0, selectedCount) {
        case 0: string("selection.select_items")
        case 1: string("selection.one_selected")
        case let count: string("selection.count_selected \(count)")
        }
    }

    /// Shared file-size formatting for settings, viewers, and model-download presentation.
    public static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The bundle backing the package String Catalog.
    public static var resourceBundle: Bundle { .module }
}
