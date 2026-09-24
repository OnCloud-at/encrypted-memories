import XCTest

@testable import PhotosCore

final class LabFeatureTests: XCTestCase {
    private let betaOnly = LabFeature(
        id: AppFeatureID(rawValue: "betaOnly"), titleKey: "t", summaryKey: "s", audience: .prereleaseBuilds)
    private let everyone = LabFeature(
        id: AppFeatureID(rawValue: "everyone"), titleKey: "t", summaryKey: "s", audience: .everyone)
    private let prerelease = AppBuildInfo(version: "1.0.5", build: "700", releaseChannel: "beta")
    private let appStore = AppBuildInfo(version: "1.0.5", build: "700", releaseChannel: "stable")

    private func makeDefaults() throws -> UserDefaults {
        let suite = "LabFeatureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testPrereleaseFeaturesStayOutOfAppStoreBuilds() {
        XCTAssertEqual(LabFeature.offered(for: prerelease, in: [betaOnly, everyone]), [betaOnly, everyone])
        XCTAssertEqual(LabFeature.offered(for: appStore, in: [betaOnly, everyone]), [everyone])
    }

    func testFeatureIsOffUntilTurnedOn() throws {
        let defaults = try makeDefaults()
        XCTAssertFalse(everyone.isEnabled(for: appStore, defaults: defaults))

        defaults.set(true, forKey: everyone.preferenceKey)
        XCTAssertTrue(everyone.isEnabled(for: appStore, defaults: defaults))
    }

    func testChoiceFromABetaStaysInertInAnAppStoreBuild() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: betaOnly.preferenceKey)

        XCTAssertTrue(betaOnly.isEnabled(for: prerelease, defaults: defaults))
        XCTAssertFalse(betaOnly.isEnabled(for: appStore, defaults: defaults))
    }

    func testEachFeatureStoresItsOwnChoice() {
        XCTAssertEqual(betaOnly.preferenceKey, "EncryptedMemories.labs.betaOnly")
        XCTAssertNotEqual(betaOnly.preferenceKey, everyone.preferenceKey)
    }

    func testCatalogFeaturesHaveDistinctIdentities() {
        XCTAssertEqual(Set(LabFeature.catalog.map(\.id)).count, LabFeature.catalog.count)
    }
}
