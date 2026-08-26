import Foundation

/// Version metadata from an app bundle, shared by diagnostics and native settings surfaces.
public struct AppBuildInfo: Sendable, Equatable {
    public let version: String?
    public let build: String?

    public init(version: String?, build: String?) {
        self.version = Self.normalized(version)
        self.build = Self.normalized(build)
    }

    public init(bundle: Bundle = .main) {
        self.init(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    public var localizedSettingsSummary: String {
        L10n.string("settings.version_build \(version ?? "—") \(build ?? "—")")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
