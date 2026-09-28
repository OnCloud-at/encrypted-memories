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

    func testSettingsShowVersionAndShortCommitButNotTheBuild() {
        let info = AppBuildInfo(version: "1.2.3", build: "683", commit: "A1B2C3D4E5F6")

        XCTAssertTrue(info.localizedVersion.contains("1.2.3"))
        XCTAssertFalse(info.localizedVersion.contains("683"))
        XCTAssertEqual(info.shortCommit, "a1b2c3d")
        XCTAssertEqual(
            info.commitURL?.absoluteString,
            "https://github.com/OnCloud-at/encrypted-memories/commit/a1b2c3d4e5f6")
    }

    func testVersionOpensItsReleaseAndPrereleasesOpenTheReleaseList() {
        XCTAssertEqual(
            AppBuildInfo(version: "1.1.0", build: "130", releaseChannel: "stable").releaseURL.absoluteString,
            "https://github.com/OnCloud-at/encrypted-memories/releases/tag/v1.1.0")
        XCTAssertEqual(
            AppBuildInfo(version: "1.1.0", build: "130", releaseChannel: "beta").releaseURL.absoluteString,
            "https://github.com/OnCloud-at/encrypted-memories/releases")
        XCTAssertEqual(
            AppBuildInfo(version: nil, build: nil).releaseURL.absoluteString,
            "https://github.com/OnCloud-at/encrypted-memories/releases")
    }

    func testInvalidCommitValuesAreIgnored() {
        for commit in [
            nil, "unknown", "$(ENCRYPTED_MEMORIES_BUILD_COMMIT)", "a1b2c3", "a1b2c3d-dirty",
            String(repeating: "a", count: 41),
        ] {
            let info = AppBuildInfo(version: "1.2.3", build: "683", commit: commit)
            XCTAssertNil(info.commit, "\(commit ?? "nil")")
            XCTAssertNil(info.shortCommit)
            XCTAssertNil(info.commitURL)
        }
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
