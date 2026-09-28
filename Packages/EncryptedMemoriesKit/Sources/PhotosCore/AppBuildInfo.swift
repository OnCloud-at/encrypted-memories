import Foundation

/// Version metadata from an app bundle, shared by diagnostics and native settings surfaces.
public struct AppBuildInfo: Sendable, Equatable {
    /// Info.plist key filled from the `ENCRYPTED_MEMORIES_PROTON_CHANNEL` build setting.
    public static let releaseChannelInfoKey = "EncryptedMemoriesProtonChannel"
    /// Info.plist key filled from the `ENCRYPTED_MEMORIES_BUILD_COMMIT` build setting.
    public static let buildCommitInfoKey = "EncryptedMemoriesBuildCommit"
    /// The public repository whose commits the builds name.
    public static let sourceRepositoryURL = URL(string: "https://github.com/OnCloud-at/encrypted-memories")!

    public let version: String?
    public let build: String?
    /// Source commit the build states about itself; nil unless it is a 7 to 40 character hexadecimal hash.
    public let commit: String?
    /// TestFlight beta builds and local development builds. App Store builds and bundles without a
    /// known release channel are never prerelease builds.
    public let isPrerelease: Bool
    /// App Store and TestFlight builds. Only CI builds them, from commits that exist on GitHub.
    public let isReleaseBuild: Bool

    public init(version: String?, build: String?, releaseChannel: String? = nil, commit: String? = nil) {
        self.version = Self.normalized(version)
        self.build = Self.normalized(build)
        self.commit = Self.normalized(commit).map { $0.lowercased() }.flatMap(Self.validCommit)
        let channel = Self.normalized(releaseChannel)?.lowercased() ?? ""
        self.isPrerelease = Self.prereleaseChannels.contains(channel)
        self.isReleaseBuild = Self.releaseChannels.contains(channel)
    }

    public init(bundle: Bundle = .main) {
        self.init(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            releaseChannel: bundle.object(forInfoDictionaryKey: Self.releaseChannelInfoKey) as? String,
            commit: bundle.object(forInfoDictionaryKey: Self.buildCommitInfoKey) as? String
        )
    }

    /// The first seven characters, as GitHub shows a commit.
    public var shortCommit: String? { commit.map { String($0.prefix(7)) } }

    /// The commit on GitHub, so anyone can match the installed app with its source and CI run. Local builds
    /// can name a commit that was never pushed, so they get no link.
    public var commitURL: URL? {
        guard isReleaseBuild, let commit else { return nil }
        return Self.sourceRepositoryURL.appendingPathComponent("commit").appendingPathComponent(commit)
    }

    /// The release page of this version. Prerelease builds do not know their beta tag, so they open the
    /// list of releases.
    public var releaseURL: URL {
        let releases = Self.sourceRepositoryURL.appendingPathComponent("releases")
        guard !isPrerelease, let version, version.allSatisfy({ $0.isNumber || $0 == "." }) else { return releases }
        return releases.appendingPathComponent("tag").appendingPathComponent("v\(version)")
    }

    /// "Version 1.2.3" for Settings. The build number stays in the support diagnostics.
    public var localizedVersion: String {
        L10n.string("settings.version \(version ?? "—")")
    }

    /// TestFlight prereleases ship as `beta`; local builds default to `alpha`.
    private static let prereleaseChannels: Set<String> = ["beta", "alpha"]
    /// Channels that only CI builds: App Store (`stable`) and TestFlight (`beta`).
    private static let releaseChannels: Set<String> = ["stable", "beta"]

    private static func validCommit(_ value: String) -> String? {
        guard (7...40).contains(value.count), value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
