import Foundation
import PhotosCore

/// Builds the `x-pm-appversion` value that Proton requires from third-party Drive clients:
/// `external-drive-{name}@{major.minor.patch}-{channel}+{build metadata}`.
///
/// The value must describe the running build honestly, so it is derived from the bundle's
/// marketing version, the release channel injected at build time, and the source commit.
public enum ProtonAppVersionHeader {
    public static let clientName = "encryptedmemories"
    /// Info.plist key filled from the `ENCRYPTED_MEMORIES_PROTON_CHANNEL` build setting.
    public static let channelInfoKey = AppBuildInfo.releaseChannelInfoKey
    /// Info.plist key filled from the `ENCRYPTED_MEMORIES_BUILD_COMMIT` build setting.
    public static let buildCommitInfoKey = "EncryptedMemoriesBuildCommit"

    public enum Channel: String, Sendable, CaseIterable {
        case stable
        case beta
        case alpha
    }

    /// Header value for the running app bundle.
    public static func current(bundle: Bundle = .main) -> String {
        value(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            channel: bundle.object(forInfoDictionaryKey: channelInfoKey) as? String,
            buildCommit: bundle.object(forInfoDictionaryKey: buildCommitInfoKey) as? String
        )
    }

    /// Unknown or malformed inputs never claim a release: the version falls back to `0.0.0`
    /// and the channel to `alpha`.
    public static func value(version: String?, channel: String?, buildCommit: String?) -> String {
        let resolvedChannel = Channel(rawValue: trimmed(channel).lowercased()) ?? .alpha
        var header = "external-drive-\(clientName)@\(semanticVersion(version))-\(resolvedChannel.rawValue)"
        if let metadata = buildMetadata(buildCommit) {
            header += "+\(metadata)"
        }
        return header
    }

    /// `1.0.3` stays unchanged; `1.2` becomes `1.2.0`; anything else becomes `0.0.0`.
    static func semanticVersion(_ version: String?) -> String {
        let parts = trimmed(version).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
            parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) })
        else { return "0.0.0" }
        let numbers = parts.map { String(Int($0) ?? 0) }
        return (numbers + Array(repeating: "0", count: 3 - numbers.count)).joined(separator: ".")
    }

    /// A lowercase hexadecimal commit, shortened to 12 characters. Placeholders are omitted.
    static func buildMetadata(_ commit: String?) -> String? {
        let value = trimmed(commit).lowercased()
        guard value.count >= 7, value.allSatisfy(\.isHexDigit) else { return nil }
        return String(value.prefix(12))
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
