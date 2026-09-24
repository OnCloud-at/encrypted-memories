import Foundation

/// Version metadata from an app bundle, shared by diagnostics and native settings surfaces.
public struct AppBuildInfo: Sendable, Equatable {
    /// Info.plist key filled from the `ENCRYPTED_MEMORIES_PROTON_CHANNEL` build setting.
    public static let releaseChannelInfoKey = "EncryptedMemoriesProtonChannel"

    public let version: String?
    public let build: String?
    /// TestFlight beta builds and local development builds. App Store builds and bundles without a
    /// known release channel are never prerelease builds.
    public let isPrerelease: Bool

    public init(version: String?, build: String?, releaseChannel: String? = nil) {
        self.version = Self.normalized(version)
        self.build = Self.normalized(build)
        self.isPrerelease = Self.prereleaseChannels.contains(Self.normalized(releaseChannel)?.lowercased() ?? "")
    }

    public init(bundle: Bundle = .main) {
        self.init(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            releaseChannel: bundle.object(forInfoDictionaryKey: Self.releaseChannelInfoKey) as? String
        )
    }

    public var localizedSettingsSummary: String {
        L10n.string("settings.version_build \(version ?? "—") \(build ?? "—")")
    }

    /// TestFlight prereleases ship as `beta`; local builds default to `alpha`.
    private static let prereleaseChannels: Set<String> = ["beta", "alpha"]

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
