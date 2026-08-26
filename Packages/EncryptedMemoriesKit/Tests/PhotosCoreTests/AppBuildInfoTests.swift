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
}
