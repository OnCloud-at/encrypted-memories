import XCTest

final class ProjectHygieneTests: XCTestCase {
    /// Returns the repository root, five levels above this test file.
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private var appDir: URL { repoRoot.appendingPathComponent("App") }
    private var uploadCoreDir: URL {
        repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Sources/UploadCore")
    }

    private func appSourceFiles() -> [URL] {
        sourceFiles(in: appDir)
    }

    private func sourceFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { ["swift", "m", "h", "mm"].contains($0.pathExtension.lowercased()) }
    }

    private func targetBlock(named target: String, in projectYML: String) -> String {
        guard let start = projectYML.range(of: "  \(target):")?.lowerBound else { return "" }
        let tail = projectYML[start...]
        guard let next = tail.range(of: "\n  [A-Za-z0-9_]+:", options: .regularExpression)?.lowerBound,
            next != tail.startIndex
        else {
            return String(tail)
        }
        return String(tail[..<next])
    }

    // Production app target uses no known private Apple API or framework.
    func testNoPrivateAppleAPIInProductionTarget() {
        let banned = ["PPApplePrivate", "loadPrivateFrameworks", "filterWithType:", "CAFilterClassNames"]
        for url in appSourceFiles() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for marker in banned {
                XCTAssertFalse(
                    text.contains(marker),
                    "\(url.lastPathComponent) contains private-API marker “\(marker)”")
            }
        }
    }

    func testEncryptedMemoriesBundleIdentifiersMatchReleaseConfiguration() throws {
        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertEqual(
            project.components(separatedBy: "PRODUCT_BUNDLE_IDENTIFIER: at.oncloud.encryptedmemories\n").count - 1,
            2,
            "iOS/iPadOS and macOS must use the same universal-purchase bundle identifier"
        )
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER: at.oncloud.encryptedmemories.tests"))
        XCTAssertFalse(
            project.contains("PRODUCT_BUNDLE_IDENTIFIER: at.oncloud.encryptedmemories.marketing-ui-tests"),
            "The private marketing UI test target must not be present in the public project"
        )

        let macTarget = targetBlock(named: "EncryptedMemories", in: project)
        XCTAssertTrue(macTarget.contains("INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO"))

        let mobileInfoData = try Data(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/Info.plist")
        )
        let mobileInfo = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: mobileInfoData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(mobileInfo["ITSAppUsesNonExemptEncryption"] as? Bool, false)
    }

    func testAppleTargetsRequireOS26OrNewer() throws {
        let projectYML = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        for target in [
            "EncryptedMemories",
            "EncryptedMemoriesMobile",
            "EncryptedMemoriesMobileTests",
        ] {
            let block = targetBlock(named: target, in: projectYML)
            XCTAssertFalse(block.isEmpty, "project.yml must define \(target)")
            XCTAssertTrue(block.contains("deploymentTarget: \"26.0\""), "\(target) must require OS 26.0+")
        }

        let manifest = try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains("platforms: [.macOS(\"26.0\"), .iOS(\"26.0\")]"))
    }

    func testProtonAppVersionHeaderInputsReachEveryShippedApp() throws {
        func read(_ path: String) throws -> String {
            try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        }
        let project = try read("project.yml")

        // x-pm-appversion is built from these bundle keys; both platforms must carry them.
        for plist in ["iOSApp/Info.plist", "App/Info.plist"] {
            let contents = try read(plist)
            XCTAssertTrue(contents.contains("<key>EncryptedMemoriesBuildCommit</key>"), plist)
            XCTAssertTrue(
                contents.contains(
                    "<key>EncryptedMemoriesProtonChannel</key>\n\t<string>$(ENCRYPTED_MEMORIES_PROTON_CHANNEL)</string>"
                ),
                plist
            )
        }
        XCTAssertTrue(project.contains("INFOPLIST_FILE: App/Info.plist"))
        XCTAssertTrue(project.contains("ENCRYPTED_MEMORIES_PROTON_CHANNEL: alpha"))
    }

    /// Background execution stays limited to BGProcessingTask work with the two identifiers the apps register.
    /// App Review rejects keep-alive modes, and an undeclared identifier fails registration only at runtime.
    func testIOSBackgroundTaskDeclarationsStayMinimal() throws {
        let infoData = try Data(contentsOf: repoRoot.appendingPathComponent("iOSApp/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertNotNil(info["NSPhotoLibraryUsageDescription"], "photo backup needs a usage description on iOS")
        XCTAssertEqual(
            info["BGTaskSchedulerPermittedIdentifiers"] as? [String],
            [
                "at.oncloud.encryptedmemories.photo-backup.processing",
                "at.oncloud.encryptedmemories.smart-search.processing",
            ])
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["processing"], "no keep-alive background mode")
    }

    func testPhotoLibraryBackupAdapterStaysUIAndSDKFree() {
        let adapterDir = repoRoot.appendingPathComponent(
            "Packages/EncryptedMemoriesKit/Sources/PhotoLibraryBackupAdapter")
        let files = sourceFiles(in: adapterDir)
        XCTAssertFalse(files.isEmpty, "the PhotoKit adapter target must exist")
        for url in files {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let importLines = Set(
                text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("import ") }
            )
            // Photos is this target's purpose; UI frameworks, OS scheduling, and the SDK are not.
            for forbidden in [
                "import UIKit",
                "import AppKit",
                "import SwiftUI",
                "import BackgroundTasks",
                "import ProtonDriveSDK",
                "import ProtonCore",
            ] {
                XCTAssertFalse(
                    importLines.contains(forbidden),
                    "\(url.lastPathComponent) must keep \(forbidden) out of the shared PhotoKit adapter")
            }
        }
    }

    func testAlbumSyncCoreStaysPureSwift() {
        let coreDir = repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Sources/AlbumSyncCore")
        let files = sourceFiles(in: coreDir)
        XCTAssertFalse(files.isEmpty, "the AlbumSyncCore target must exist")
        for url in files {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let importLines = Set(
                text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("import ") }
            )
            // The sync engine is universal: platform frameworks, PhotoKit, and the SDK live in
            // adapters only.
            for forbidden in [
                "import UIKit",
                "import AppKit",
                "import SwiftUI",
                "import Photos",
                "import PhotosUI",
                "import BackgroundTasks",
                "import ProtonDriveSDK",
                "import ProtonCore",
            ] {
                XCTAssertFalse(
                    importLines.contains(forbidden),
                    "\(url.lastPathComponent) must keep \(forbidden) out of AlbumSyncCore")
            }
        }
    }

    func testMobileAppStoreDeviceCapabilitiesDeclareRendererFloor() throws {
        let infoData = try Data(contentsOf: repoRoot.appendingPathComponent("iOSApp/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
        let capabilities = try XCTUnwrap(info["UIRequiredDeviceCapabilities"] as? [String])

        XCTAssertTrue(capabilities.contains("arm64"))
        XCTAssertTrue(capabilities.contains("metal"))
        XCTAssertTrue(
            capabilities.contains("iphone-ipad-minimum-performance-a12"),
            "App Store distribution must exclude devices below the closest available hardware floor"
        )

        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO"))
        XCTAssertTrue(project.contains("SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD: NO"))
        XCTAssertTrue(project.contains("INFOPLIST_KEY_NSHumanReadableCopyright:"))
    }

    func testUploadCoreStaysPlatformAndSDKAgnostic() {
        for url in sourceFiles(in: uploadCoreDir) {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let importLines = Set(
                text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("import ") }
            )
            for forbidden in [
                "import AppKit",
                "import UIKit",
                "import Photos",
                "import PhotosUI",
                "import BackgroundTasks",
                "import ProtonDriveSDK",
                "import ProtonCore",
            ] {
                XCTAssertFalse(
                    importLines.contains(forbidden),
                    "\(url.lastPathComponent) must keep platform/API adapters out of UploadCore")
            }
        }
    }

    func testMacAppEntitlementsStaySandboxedAndMinimal() throws {
        let entitlementsURL = repoRoot.appendingPathComponent("App/EncryptedMemories.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            "macOS entitlements must remain a dictionary plist"
        )

        for required in [
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client",
            "com.apple.security.files.user-selected.read-write",
            // Folder backup persists the user's chosen folders as security-scoped bookmarks.
            "com.apple.security.files.bookmarks.app-scope",
            // Photos-library backup reads originals through PhotoKit.
            "com.apple.security.personal-information.photos-library",
        ] {
            XCTAssertEqual(plist[required] as? Bool, true, "missing required entitlement \(required)")
        }

        for forbidden in [
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.allow-unsigned-executable-memory",
            "com.apple.security.cs.allow-jit",
            "com.apple.security.files.downloads.read-write",
            "com.apple.security.files.pictures.read-write",
            "com.apple.security.temporary-exception.files.absolute-path.read-write",
            "com.apple.security.temporary-exception.files.home-relative-path.read-write",
        ] {
            XCTAssertNil(plist[forbidden], "entitlement \(forbidden) must not be present without a documented need")
        }
    }

    func testPlatformAppsShipPrivacyManifestsForRequiredReasonAPIs() throws {
        let relativePath = "Shared/PrivacyInfo.xcprivacy"
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            "\(relativePath) must be a dictionary plist"
        )

        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false, "\(relativePath) must not declare tracking")
        let collectedData = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let collectedDataByType = Dictionary(
            uniqueKeysWithValues: collectedData.compactMap { entry -> (String, [String: Any])? in
                guard let type = entry["NSPrivacyCollectedDataType"] as? String else { return nil }
                return (type, entry)
            }
        )
        XCTAssertEqual(
            Set(collectedDataByType.keys),
            [
                "NSPrivacyCollectedDataTypeCrashData",
                "NSPrivacyCollectedDataTypeOtherDiagnosticData",
            ]
        )
        for (type, entry) in collectedDataByType {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, false, "\(type) must not be linked")
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, "\(type) must not track")
            XCTAssertEqual(
                entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
            )
        }

        let apiTypes = try XCTUnwrap(
            plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
            "\(relativePath) must declare required-reason API use"
        )
        let reasonsByType = Dictionary(
            uniqueKeysWithValues: apiTypes.compactMap { entry -> (String, Set<String>)? in
                guard let type = entry["NSPrivacyAccessedAPIType"] as? String,
                    let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
                else { return nil }
                return (type, Set(reasons))
            }
        )

        XCTAssertEqual(reasonsByType["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasonsByType["NSPrivacyAccessedAPICategoryDiskSpace"], ["E174.1"])
        XCTAssertEqual(
            reasonsByType["NSPrivacyAccessedAPICategoryFileTimestamp"],
            ["C617.1", "3B52.1"]
        )

        let projectYML = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertEqual(
            projectYML.components(separatedBy: "- Shared/PrivacyInfo.xcprivacy").count - 1,
            2,
            "macOS and iOS/iPadOS targets must embed the one shared privacy manifest"
        )
    }
}
