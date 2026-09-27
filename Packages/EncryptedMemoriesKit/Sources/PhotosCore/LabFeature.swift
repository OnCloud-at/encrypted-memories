import Foundation

/// A feature that people can try in Settings › Labs before it ships to everyone.
///
/// Labs itself is always visible. Each feature decides separately which builds offer it, and a
/// feature is on only while its build offers it and the person turned it on.
public struct LabFeature: Identifiable, Sendable, Equatable {
    /// Builds that offer the feature in Labs.
    public enum Audience: Sendable, Equatable {
        /// TestFlight beta builds and local development builds.
        case prereleaseBuilds
        /// Every build, including App Store builds.
        case everyone
    }

    public let id: AppFeatureID
    /// Package catalog key for the toggle title.
    public let titleKey: String
    /// Package catalog key for the one-line description under the title.
    public let summaryKey: String
    public let audience: Audience

    public init(id: AppFeatureID, titleKey: String, summaryKey: String, audience: Audience) {
        self.id = id
        self.titleKey = titleKey
        self.summaryKey = summaryKey
        self.audience = audience
    }

    /// Features in Labs, in display order. Empty while nothing is ready for testing.
    public static let catalog: [LabFeature] = []

    /// Features that `build` offers, in catalog order.
    public static func offered(for build: AppBuildInfo, in catalog: [LabFeature] = catalog) -> [LabFeature] {
        catalog.filter { $0.isOffered(for: build) }
    }

    public var localizedTitle: String { L10n.string(dynamicKey: titleKey) }
    public var localizedSummary: String { L10n.string(dynamicKey: summaryKey) }

    /// Preference that stores whether the person turned the feature on. Sign-out clears it together
    /// with every other app preference.
    public var preferenceKey: String { "EncryptedMemories.labs.\(id.rawValue)" }

    public func isOffered(for build: AppBuildInfo) -> Bool {
        switch audience {
        case .prereleaseBuilds: build.isPrerelease
        case .everyone: true
        }
    }

    /// A stored choice from a prerelease build stays inert in a build that does not offer the feature.
    public func isEnabled(for build: AppBuildInfo, defaults: UserDefaults = .standard) -> Bool {
        isOffered(for: build) && defaults.bool(forKey: preferenceKey)
    }
}
