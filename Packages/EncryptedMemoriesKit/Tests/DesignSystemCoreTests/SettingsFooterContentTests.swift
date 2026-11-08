import PhotosCore
import Testing

@testable import DesignSystemCore

@Suite struct SettingsFooterContentTests {
    @Test func contentKeepsVersionCommitAndAttributionInOrder() {
        let info = AppBuildInfo(version: "1.2.3", build: "42", commit: "a1b2c3d4")
        #expect(
            SettingsFooterContent(info: info).items == [
                .link(info.localizedVersion, info.releaseURL),
                .link("a1b2c3d", info.commitURL!),
                .text(ProductBrand.madeInAustria),
            ])
    }

    @Test func contentOmitsAnUnavailableCommit() {
        let info = AppBuildInfo(version: "1.2.3", build: nil)
        #expect(
            SettingsFooterContent(info: info).items == [
                .link(info.localizedVersion, info.releaseURL),
                .text(ProductBrand.madeInAustria),
            ])
    }
}
