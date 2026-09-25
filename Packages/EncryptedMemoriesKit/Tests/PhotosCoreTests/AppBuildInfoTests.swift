import XCTest

@testable import PhotosCore

final class AppBuildInfoTests: XCTestCase {
    func testNormalizesBundleValues() {
        XCTAssertEqual(
            AppBuildInfo(version: " 1.2.3 ", build: " 683 "),
            AppBuildInfo(version: "1.2.3", build: "683")
        )
        XCTAssertNil(AppBuildInfo(version: "  ", build: nil).version)
        XCTAssertNil(AppBuildInfo(version: nil, build: "\n").build)
    }

    func testSettingsSummaryIncludesVersionAndBuild() {
        let summary = AppBuildInfo(version: "1.2.3", build: "683").localizedSettingsSummary

        XCTAssertTrue(summary.contains("1.2.3"))
        XCTAssertTrue(summary.contains("683"))
    }

    func testOnlyBetaAndDevelopmentChannelsArePrereleaseBuilds() {
        XCTAssertTrue(AppBuildInfo(version: nil, build: nil, releaseChannel: "beta").isPrerelease)
        XCTAssertTrue(AppBuildInfo(version: nil, build: nil, releaseChannel: " Alpha\n").isPrerelease)
        XCTAssertFalse(AppBuildInfo(version: nil, build: nil, releaseChannel: "stable").isPrerelease)
        // A missing or unknown channel never unlocks prerelease features.
        XCTAssertFalse(AppBuildInfo(version: nil, build: nil).isPrerelease)
        XCTAssertFalse(AppBuildInfo(version: nil, build: nil, releaseChannel: "").isPrerelease)
        XCTAssertFalse(
            AppBuildInfo(version: nil, build: nil, releaseChannel: "$(ENCRYPTED_MEMORIES_PROTON_CHANNEL)").isPrerelease)
    }
}
