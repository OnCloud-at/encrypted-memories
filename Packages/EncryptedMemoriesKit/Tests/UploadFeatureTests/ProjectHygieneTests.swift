import XCTest

final class ProjectHygieneTests: XCTestCase {
    /// Returns the repository root, five levels above this test file.
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private var appDir: URL { repoRoot.appendingPathComponent("App") }
    private var mobileAppDir: URL { repoRoot.appendingPathComponent("iOSApp") }
    private var uploadCoreDir: URL {
        repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Sources/UploadCore")
    }

    private func appSourceFiles() -> [URL] {
        sourceFiles(in: appDir)
    }

    private func mobileAppSourceFiles() -> [URL] {
        sourceFiles(in: mobileAppDir)
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

    private func sourceBlock(from startMarker: String, to endMarker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let tail = source[start...]
        let end = try XCTUnwrap(tail.range(of: endMarker)?.lowerBound)
        return String(tail[..<end])
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

    func testSettingsSurfacesShareVersionAndBuildPresentation() throws {
        let sharedLabel = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/DesignSystemCore/AppBuildInfoLabel.swift"
            ),
            encoding: .utf8
        )
        let macSettings = try String(
            contentsOf: repoRoot.appendingPathComponent("App/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let mobileSettings = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileSettingsScreen.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(sharedLabel.contains("AppBuildInfo"))
        XCTAssertTrue(macSettings.contains("AppBuildInfoLabel()"))
        XCTAssertTrue(mobileSettings.contains("AppBuildInfoLabel()"))
        for source in [macSettings, mobileSettings] {
            XCTAssertFalse(source.contains("CFBundleShortVersionString"))
            XCTAssertFalse(source.contains("CFBundleVersion"))
        }
    }

    func testMacSettingsPlacesStoreKitSupportImmediatelyAfterAccount() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("App/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let accountTab = try XCTUnwrap(source.range(of: "AccountSettingsTab(signOut:"))
        let supportTab = try XCTUnwrap(source.range(of: "SupportSettingsTab()"))
        let libraryTab = try XCTUnwrap(source.range(of: "LibrarySettingsTab()"))

        XCTAssertLessThan(accountTab.lowerBound, supportTab.lowerBound)
        XCTAssertLessThan(supportTab.lowerBound, libraryTab.lowerBound)
        XCTAssertTrue(source.contains("Label(L10n.string(\"settings.support_tab\"), systemImage: \"heart\")"))
        XCTAssertTrue(source.contains("@Environment(\\.dismissWindow)"))
        let dismissCall = try XCTUnwrap(source.range(of: "dismissWindow()"))
        let signOutCall = try XCTUnwrap(source.range(of: "signOut()"))
        XCTAssertLessThan(dismissCall.lowerBound, signOutCall.lowerBound)
        XCTAssertTrue(source.contains("if isAccountAvailable"))

        let accountBlock = try sourceBlock(
            from: "private struct AccountSettingsTab: View",
            to: "private struct SupportSettingsTab: View",
            in: source
        )
        let supportBlock = try sourceBlock(
            from: "private struct SupportSettingsTab: View",
            to: "private struct LibrarySettingsTab: View",
            in: source
        )
        XCTAssertFalse(accountBlock.contains("TipJarView()"))
        XCTAssertTrue(supportBlock.contains("TipJarView()"))

        let tipJar = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/DesignSystemCore/TipJarView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(tipJar.contains(".storeButton(.hidden, for: .restorePurchases, .cancellation)"))
        XCTAssertTrue(tipJar.contains("Product.products(for: productIdentifiers)"))
        XCTAssertTrue(tipJar.contains("StoreView(products: products)"))
        XCTAssertFalse(tipJar.contains("StoreView(ids: productIdentifiers)"))
        XCTAssertTrue(tipJar.contains("guard !availableProductIdentifiers.isEmpty else"))
        XCTAssertTrue(tipJar.contains("TipJarProductAvailability.orderedAvailableIdentifiers"))
        XCTAssertTrue(tipJar.contains("if !missingProductIdentifiers.isEmpty"))

        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertFalse(
            project.contains("storeKitConfiguration:"),
            "native runs must use App Store Connect data so sandbox testing matches App Review"
        )
        XCTAssertFalse(
            project.contains("  - StoreKit\n"),
            "a clean checkout must not reference a deleted local StoreKit directory"
        )
        XCTAssertFalse(
            project.contains("com.apple.InAppPurchase"),
            "XcodeGen 2.46 serializes nested capability attributes incorrectly"
        )
        XCTAssertFalse(
            project.contains("com.apple.developer.in-app-purchase"),
            "In-App Purchase does not define an application entitlement"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent("StoreKit/EncryptedMemories.storekit").path
            ),
            "the repository must not provide local products that can mask App Store Connect configuration errors"
        )
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

        let rebuild = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/rebuild.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(rebuild.contains("IOS_BUNDLE_ID=\"at.oncloud.encryptedmemories\""))
        XCTAssertEqual(rebuild.components(separatedBy: "IOS_BUNDLE_ID=").count - 1, 1)
    }

    func testAppleDistributionBuildsOnceAndPromotesExistingBuilds() throws {
        let buildPaths = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/build-paths.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(buildPaths.contains("BuildSupport/Package.resolved"))
        XCTAssertTrue(buildPaths.contains("local sdk_lock=\"$canonical_lock\""))

        let internalWorkflow = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/testflight-internal.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(internalWorkflow.contains("workflow_dispatch:"))
        XCTAssertTrue(internalWorkflow.contains("release:"))
        XCTAssertTrue(internalWorkflow.contains("types: [published]"))
        XCTAssertTrue(internalWorkflow.contains("group: apple-distribution"))
        XCTAssertTrue(internalWorkflow.contains("environment: testflight-internal"))
        XCTAssertTrue(internalWorkflow.contains("environment: app-store-production"))
        XCTAssertTrue(internalWorkflow.contains("api_platform: IOS"))
        XCTAssertTrue(internalWorkflow.contains("api_platform: MAC_OS"))
        XCTAssertTrue(internalWorkflow.contains("Apple-Actions/import-codesign-certs@"))
        XCTAssertTrue(internalWorkflow.contains("Import certificates with pinned community action"))
        XCTAssertTrue(internalWorkflow.contains("keychain: encrypted_memories_signing"))
        XCTAssertTrue(internalWorkflow.contains("p12-filepath: ${{ runner.temp }}/apple-signing-certificates.p12"))
        XCTAssertFalse(internalWorkflow.contains("p12-file-base64:"))
        XCTAssertTrue(internalWorkflow.contains("security find-identity -v encrypted_memories_signing.keychain"))
        XCTAssertTrue(internalWorkflow.contains("fastlane sigh"))
        XCTAssertTrue(internalWorkflow.contains("--force"))
        XCTAssertTrue(internalWorkflow.contains("FASTLANE_MIN_VERSION: \"2.237.0\""))
        XCTAssertTrue(internalWorkflow.contains("FASTLANE_MAX_VERSION: \"3.0.0\""))
        XCTAssertFalse(internalWorkflow.contains("FASTLANE_VERSION:"))
        XCTAssertTrue(internalWorkflow.contains("xcrun xcodebuild archive"))
        XCTAssertTrue(internalWorkflow.contains("xcrun xcodebuild -exportArchive"))
        XCTAssertTrue(internalWorkflow.contains("xcrun altool --upload-package"))
        XCTAssertTrue(internalWorkflow.contains("validate_apple_distribution.sh"))
        XCTAssertTrue(internalWorkflow.contains("ENCRYPTED_MEMORIES_PROVISIONING_PROFILE_SPECIFIER"))
        XCTAssertTrue(internalWorkflow.contains("installerSigningCertificate"))
        XCTAssertTrue(internalWorkflow.contains("steps.signing-identities.outputs.installer_sha1"))
        XCTAssertTrue(
            internalWorkflow.contains(
                "DeveloperCertificates.$profile_certificate_count"
            )
        )
        XCTAssertTrue(internalWorkflow.contains("profile_certificate_sha1"))
        XCTAssertTrue(internalWorkflow.contains("Print :Entitlements:$PROFILE_APP_IDENTIFIER_KEY"))
        XCTAssertTrue(internalWorkflow.contains("rm -f \"$RUNNER_TEMP/apple-signing-certificates.p12\""))
        XCTAssertFalse(internalWorkflow.contains("3rd Party Mac Developer Installer\""))
        XCTAssertFalse(internalWorkflow.contains("xcbeautify"))
        XCTAssertTrue(internalWorkflow.contains("secrets.APP_STORE_CONNECT_PRIVATE_KEY_BASE64"))
        XCTAssertFalse(internalWorkflow.contains("secrets.APP_STORE_CONNECT_PRIVATE_KEY }}"))
        XCTAssertFalse(internalWorkflow.contains("-allowProvisioningUpdates"))
        XCTAssertTrue(internalWorkflow.contains("Validate StoreKit sandbox metadata"))
        XCTAssertTrue(internalWorkflow.contains("validate-sandbox-in-app-purchases"))
        XCTAssertTrue(internalWorkflow.contains("validate-build-number"))
        XCTAssertTrue(internalWorkflow.contains("steps.revision.outputs.build_number"))
        XCTAssertFalse(internalWorkflow.contains("steps.release.outputs.build_number"))
        XCTAssertTrue(internalWorkflow.contains("needs: [prepare, in-app-purchase-preflight]"))
        XCTAssertTrue(internalWorkflow.contains("distribute-internal"))
        XCTAssertTrue(internalWorkflow.contains("prepare-app-store"))
        XCTAssertTrue(internalWorkflow.contains("--create-versions"))
        XCTAssertTrue(internalWorkflow.contains("--automatic-release"))
        XCTAssertTrue(internalWorkflow.contains("--submit"))
        XCTAssertFalse(internalWorkflow.contains("distribute-external"))

        let externalWorkflow = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/testflight-external.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(externalWorkflow.contains("workflow_dispatch:"))
        XCTAssertTrue(externalWorkflow.contains("group: apple-distribution"))
        XCTAssertTrue(externalWorkflow.contains("environment: testflight-external"))
        XCTAssertTrue(externalWorkflow.contains("distribute-external"))
        XCTAssertTrue(externalWorkflow.contains("wait-builds"))
        XCTAssertTrue(externalWorkflow.contains("release_build_number.rb"))
        XCTAssertTrue(externalWorkflow.contains("steps.build.outputs.build_number"))
        XCTAssertFalse(externalWorkflow.contains("steps.release.outputs.build_number"))
        XCTAssertFalse(externalWorkflow.contains("xcrun xcodebuild"))
        XCTAssertFalse(externalWorkflow.contains("xcrun altool"))
        XCTAssertFalse(externalWorkflow.contains("Apple-Actions/import-codesign-certs@"))

        let prepareAppleBuild = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/actions/prepare-apple-build/action.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(prepareAppleBuild.contains("-resolvePackageDependencies"))
        XCTAssertTrue(prepareAppleBuild.contains("-packageAuthorizationProvider netrc"))

        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertEqual(
            project.components(
                separatedBy: "CODE_SIGN_STYLE: $(ENCRYPTED_MEMORIES_CODE_SIGN_STYLE)"
            ).count - 1,
            2
        )
        XCTAssertEqual(
            project.components(
                separatedBy: "PROVISIONING_PROFILE_SPECIFIER: $(ENCRYPTED_MEMORIES_PROVISIONING_PROFILE_SPECIFIER)"
            ).count - 1,
            2
        )

        for retiredWorkflow in [
            "app-store-preflight.yml",
            "app-store-release.yml",
            "app-store-publish.yml",
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: repoRoot.appendingPathComponent(".github/workflows/\(retiredWorkflow)").path
                )
            )
        }

        let releaseContract = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/scripts/release_contract.rb"),
            encoding: .utf8
        )
        XCTAssertTrue(releaseContract.contains("TAG_PATTERN"))
        XCTAssertTrue(releaseContract.contains("beta|rc"))
        XCTAssertTrue(releaseContract.contains("payload.fetch(\"id\")"))
        XCTAssertTrue(releaseContract.contains("\"de-DE\" => \"Deutsch\""))
        XCTAssertTrue(releaseContract.contains("\"en-US\" => \"English\""))

        let buildNumberContract = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/scripts/release_build_number.rb"),
            encoding: .utf8
        )
        XCTAssertTrue(buildNumberContract.contains("68c8f3f7de98ce4b3385f655d97252d40dd2378e"))
        XCTAssertTrue(buildNumberContract.contains("BASELINE_BUILD_NUMBER = 382_818_668"))
        XCTAssertTrue(buildNumberContract.contains("git\", \"rev-list\", \"--first-parent"))
        XCTAssertTrue(buildNumberContract.contains("build_number=#{build_number}"))

        let validationScript = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/scripts/validate_apple_distribution.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(validationScript.contains("pkgutil --check-signature"))
        XCTAssertTrue(validationScript.contains("Authority=Apple Distribution:"))
        XCTAssertTrue(validationScript.contains("expected_profile_name"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent(".github/scripts/archive_and_upload.sh").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent(".github/scripts/install_apple_signing.sh").path
            )
        )

        let connectScript = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/scripts/app_store_connect.rb"),
            encoding: .utf8
        )
        XCTAssertTrue(connectScript.contains("/v1/betaAppReviewSubmissions"))
        XCTAssertTrue(connectScript.contains("/v1/reviewSubmissions"))
        XCTAssertTrue(connectScript.contains("/v1/apps/#{@app_id}/inAppPurchasesV2"))
        XCTAssertTrue(connectScript.contains("/v1/bundleIds"))
        XCTAssertTrue(connectScript.contains("/bundleIdCapabilities"))
        XCTAssertTrue(connectScript.contains("IN_APP_PURCHASE"))
        XCTAssertTrue(connectScript.contains("/v2/inAppPurchases/#{product.fetch('id')}/versions"))
        XCTAssertTrue(connectScript.contains("/v1/inAppPurchaseVersions/#{version.fetch('id')}/localizations"))
        XCTAssertTrue(
            connectScript.contains(
                "\"fields[inAppPurchases]\" => \"name,productId,inAppPurchaseType,state,reviewNote\""
            )
        )
        XCTAssertTrue(
            connectScript.contains(
                "\"fields[inAppPurchaseLocalizations]\" => \"name,locale\""
            )
        )
        XCTAssertFalse(connectScript.contains("name,locale,description"))
        XCTAssertFalse(connectScript.contains("\"include\" => \"inAppPurchaseLocalizations\""))
        XCTAssertTrue(connectScript.contains("releaseType: \"AFTER_APPROVAL\""))
        XCTAssertTrue(connectScript.contains("validate_build_number"))
        XCTAssertTrue(connectScript.contains("build_history_filters"))
        XCTAssertFalse(connectScript.contains("/v1/appStoreVersionReleaseRequests"))
        XCTAssertTrue(connectScript.contains("automatic submission requires APPROVED products"))
        XCTAssertFalse(connectScript.contains("All four consumable tips"))
        XCTAssertTrue(connectScript.contains("iosBuildsAvailableForAppleSiliconMac: false"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("ci_scripts").path))

        let inAppPurchaseContract = try Data(
            contentsOf: repoRoot.appendingPathComponent(".github/app-store-connect/in-app-purchases.json")
        )
        let inAppPurchaseDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(with: inAppPurchaseContract) as? [String: Any]
        )
        XCTAssertEqual(inAppPurchaseDocument["bundleIdentifier"] as? String, "at.oncloud.encryptedmemories")
        XCTAssertEqual(inAppPurchaseDocument["requiredTerritories"] as? [String], ["AUT", "USA"])
        let products = try XCTUnwrap(inAppPurchaseDocument["products"] as? [[String: Any]])
        let productIDs = products.compactMap { $0["productId"] as? String }
        XCTAssertEqual(
            productIDs,
            [
                "at.oncloud.encryptedmemories.tip.s",
                "at.oncloud.encryptedmemories.tip.medium",
                "at.oncloud.encryptedmemories.tip.large",
                "at.oncloud.encryptedmemories.tip.extra_large",
            ]
        )
        XCTAssertEqual(Set(productIDs).count, productIDs.count)
        XCTAssertTrue(products.allSatisfy { $0["type"] as? String == "CONSUMABLE" })

        for locale in ["en-US", "de-DE"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: repoRoot.appendingPathComponent("TestFlight/WhatToTest.\(locale).txt").path
                )
            )
        }

        let resolved = try Data(
            contentsOf: repoRoot.appendingPathComponent("BuildSupport/Package.resolved")
        )
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: resolved))
    }

    func testPullRequestArchitectureProofUsesIsolatedPlatformShards() throws {
        let workflow = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/pull-request.yml"),
            encoding: .utf8
        )
        XCTAssertEqual(
            workflow.components(separatedBy: "needs: [repository-hygiene, code-quality]").count - 1,
            5,
            "Every expensive PR job must wait for both fast checks"
        )
        let shards = try sourceBlock(
            from: "  architecture-builds:\n",
            to: "  architecture:\n",
            in: workflow
        )
        XCTAssertTrue(shards.contains("name: Shared architecture (${{ matrix.platform }})"))
        XCTAssertTrue(shards.contains("fail-fast: false"))
        XCTAssertTrue(shards.contains("max-parallel: 2"))
        XCTAssertTrue(shards.contains("mode: build-ios"))
        XCTAssertTrue(shards.contains("mode: build-macos"))
        XCTAssertTrue(shards.contains("verify-universal-core.sh \"${{ matrix.mode }}\""))

        let aggregator = try sourceBlock(
            from: "  architecture:\n",
            to: "  macos-app-shell:\n",
            in: workflow
        )
        XCTAssertTrue(aggregator.contains("name: Shared architecture\n"))
        XCTAssertTrue(aggregator.contains("needs: [package-tests, architecture-builds]"))
        XCTAssertTrue(aggregator.contains("if: ${{ always() }}"))
        XCTAssertTrue(aggregator.contains("PACKAGE_TESTS_RESULT"))
        XCTAssertTrue(aggregator.contains("ARCHITECTURE_BUILDS_RESULT"))

        let verifier = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/verify-universal-core.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(verifier.contains("fast|full|build-ios|build-macos"))
        XCTAssertTrue(verifier.contains("RUN_ARCHITECTURE_TESTS=false"))
        XCTAssertTrue(verifier.contains("BUILD_IOS=false"))
        XCTAssertTrue(verifier.contains("BUILD_MACOS=false"))
    }

    func testWorkspaceReferencesTheGeneratedProject() throws {
        let workspace = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "EncryptedMemories.xcworkspace/contents.xcworkspacedata"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(workspace.contains("group:EncryptedMemories.xcodeproj"))
        let gitignore = try String(
            contentsOf: repoRoot.appendingPathComponent(".gitignore"),
            encoding: .utf8
        )
        XCTAssertTrue(gitignore.contains("EncryptedMemories.xcodeproj/"))
    }

    func testPublicRepositoryBoundaryRejectsInternalArtifacts() throws {
        let workflow = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/pull-request.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(workflow.contains("bash scripts/check-public-tree.sh"))

        let boundary = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/check-public-tree.sh"),
            encoding: .utf8
        )
        for marker in [
            "*.aiff",
            "*.mp4",
            "Marketing/Audio/*",
            "Marketing/Captures/*",
            "Marketing/Review/*",
            "EncryptedMemories.xcodeproj/*",
            "*/__pycache__/*",
            "fastlane/*",
            "scripts/archive-app-store.sh",
            "THIRD_PARTY_NOTICES",
            "APPLE_RELEASE_SETUP.rst",
        ] {
            XCTAssertTrue(boundary.contains(marker), "public boundary missing \(marker)")
        }
        XCTAssertTrue(boundary.contains("git ls-files -z --format="))

        let modeNormalizer = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/normalize-public-index-modes.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(modeNormalizer.contains("git update-index --chmod=-x"))
        XCTAssertTrue(modeNormalizer.contains("git update-index --chmod=+x"))

        let gitignore = try String(
            contentsOf: repoRoot.appendingPathComponent(".gitignore"),
            encoding: .utf8
        )
        for marker in [
            "*.md",
            "__pycache__/",
            "*.py[cod]",
            "/Marketing/",
            "/site/assets/*.m4v",
            "/site/assets/*.mov",
            "/site/assets/*.mp4",
        ] {
            XCTAssertTrue(gitignore.contains(marker), ".gitignore missing \(marker)")
        }

        let site = try String(
            contentsOf: repoRoot.appendingPathComponent("site/index.html"),
            encoding: .utf8
        )
        XCTAssertFalse(site.contains("<video"), "unapproved marketing video must stay outside Pages")
        XCTAssertFalse(site.contains(".mp4"), "Pages must not reference an ignored video")
    }

    func testAppleViewerSurfacesUseTheSharedStreamedDecoder() throws {
        let macViewer = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/PhotoViewerModel.swift"
            ),
            encoding: .utf8
        )
        let mobileViewer = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerUIKitAdapter/UIKitViewerImageStore.swift"
            ),
            encoding: .utf8
        )

        for source in [macViewer, mobileViewer] {
            XCTAssertTrue(source.contains("ViewerFullImageDecoder.decodeStreamedCGImage("))
        }
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

    func testUserWikiStaysBuiltInAndIssuesAcceptSupportRequests() throws {
        let wikiRoot = repoRoot.appendingPathComponent("Wiki")
        for page in [
            "Home.md",
            "Quick-Start.md",
            "Device-and-Feature-Support.md",
            "Sign-In.md",
            "Library.md",
            "Collections.md",
            "Albums.md",
            "Map.md",
            "Smart-Search.md",
            "Photo-and-Video-Viewer.md",
            "Media-Information.md",
            "Recently-Deleted.md",
            "Backup-and-Album-Sync.md",
            "Uploads-and-Queue.md",
            "Album-Sync.md",
            "Settings-Cache-and-Privacy.md",
            "Troubleshooting.md",
            "Support-and-Feedback.md",
            "_Sidebar.md",
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: wikiRoot.appendingPathComponent(page).path),
                "reviewed Wiki source is missing \(page)"
            )
        }

        let compatibility = try String(
            contentsOf: wikiRoot.appendingPathComponent("Device-and-Feature-Support.md"),
            encoding: .utf8
        )
        for requirement in ["iOS 26.0", "iPadOS 26.0", "macOS 26.0", "Metal 3", "Neural Engine"] {
            XCTAssertTrue(compatibility.contains(requirement), "compatibility Wiki missing \(requirement)")
        }

        let publisher = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/publish-wiki.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(publisher.contains("OnCloud-at/encrypted-memories.wiki.git"))
        XCTAssertFalse(publisher.contains("OnCloud-at/encrypted-memories-wiki.git"))

        let chooser = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/ISSUE_TEMPLATE/config.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(chooser.contains("blank_issues_enabled: false"))
        XCTAssertTrue(chooser.contains("https://github.com/OnCloud-at/encrypted-memories/wiki"))
        XCTAssertTrue(chooser.contains("select Support request above"))

        for template in ["bug_report.yml", "feature_request.yml"] {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(".github/ISSUE_TEMPLATE/\(template)"),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("not a usage question"))
        }

        let supportTemplate = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/ISSUE_TEMPLATE/support_request.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(supportTemplate.contains("name: Support request"))
        XCTAssertTrue(supportTemplate.contains("official support channel"))
        XCTAssertTrue(supportTemplate.contains("Ask a question or request help"))
        XCTAssertTrue(supportTemplate.contains("- question"))
    }

    func testAppleAppsShareMetal3HardwareGateAndFallback() throws {
        let sharedGate = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/MetalRenderingCore/Metal3RuntimeCapability.swift"
            ),
            encoding: .utf8
        )
        let sharedFallback = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/DesignSystemCore/Metal3UnsupportedDeviceView.swift"
            ),
            encoding: .utf8
        )
        let macApp = try String(
            contentsOf: repoRoot.appendingPathComponent("App/EncryptedMemoriesApp.swift"),
            encoding: .utf8
        )
        let mobileApp = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/EncryptedMemoriesMobileApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(sharedGate.contains("device.supportsFamily(.metal3)"))
        XCTAssertTrue(sharedFallback.contains("MemoriesBrandMark(height: 68)"))
        XCTAssertTrue(sharedFallback.contains("device.unsupported_reassurance"))
        XCTAssertTrue(macApp.contains("Metal3RuntimeCapability.supportsDefaultDevice()"))
        XCTAssertTrue(macApp.contains("@State private var model: AppModel?"))
        XCTAssertTrue(macApp.contains("_model = State(initialValue: metal3Supported ? AppModel() : nil)"))
        XCTAssertTrue(macApp.contains("if let model"))
        XCTAssertTrue(macApp.contains("Metal3UnsupportedDeviceView(productName: ProductBrand.displayName)"))
        XCTAssertTrue(mobileApp.contains("guard metal3Supported else { return }"))
        XCTAssertTrue(mobileApp.contains("if metal3Supported {\n                MobileSupportedAppRoot()"))
        XCTAssertTrue(mobileApp.contains("private struct MobileSupportedAppRoot: View"))
        XCTAssertTrue(mobileApp.contains("UIKitTimelineMetalCapability.supportsTimelineGrid(device: device)"))
        XCTAssertTrue(mobileApp.contains("Metal3UnsupportedDeviceView(productName: ProductBrand.displayName)"))

        let supportedRootDeclaration = try XCTUnwrap(mobileApp.range(of: "private struct MobileSupportedAppRoot: View"))
        let sessionConstruction = try XCTUnwrap(mobileApp.range(of: "MobileSessionModel()"))
        XCTAssertLessThan(
            mobileApp.distance(from: mobileApp.startIndex, to: supportedRootDeclaration.lowerBound),
            mobileApp.distance(from: mobileApp.startIndex, to: sessionConstruction.lowerBound),
            "mobile auth state must only be constructed inside the supported-device root"
        )
    }

    func testMobileShellTargetStaysUniversalAndUIKitOnly() throws {
        let projectYML =
            (try? String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)) ?? ""
        let mobileTarget = targetBlock(named: "EncryptedMemoriesMobile", in: projectYML)
        XCTAssertFalse(mobileTarget.isEmpty, "project.yml must define the EncryptedMemoriesMobile iOS shell target")

        for required in [
            "platform: iOS",
            "deploymentTarget: \"26.0\"",
            "TARGETED_DEVICE_FAMILY: \"1,2\"",
            "product: PhotosCore",
            "product: ProtonAuth",
            "product: ProtonDriveBackend",
            "product: TimelineUIKitAdapter",
            "product: TimelineUIKitFeature",
            "product: MediaCacheUIKitAdapter",
            "product: MediaCacheCore",
            "product: MetalGridTextureUIKitAdapter",
            "product: AlbumsFeature",
            "product: PhotoViewerCore",
            "product: PhotoViewerUIKitAdapter",
            "product: MapUIKitAdapter",
            "product: UploadCore",
            "product: UploadFeature",
            "product: PhotoLibraryBackupAdapter",
        ] {
            XCTAssertTrue(mobileTarget.contains(required), "EncryptedMemoriesMobile target missing \(required)")
        }

        for forbidden in [
            "product: DesignSystem\n",
            "product: MediaCache\n",
            "product: TimelineFeature",
            "product: PhotoViewerFeature",
            "product: MapFeature",
            "product: ProtonDriveSDK",
        ] {
            XCTAssertFalse(mobileTarget.contains(forbidden), "iOS shell must not depend on \(forbidden)")
        }

        for url in mobileAppSourceFiles() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let importLines = Set(
                text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("import ") }
            )
            for forbidden in [
                "import AppKit",
                "import TimelineFeature",
                "import PhotoViewerFeature",
                "import MapFeature",
                "NSView",
                "NSImage",
                "NSScrollView",
            ] {
                XCTAssertFalse(
                    text.contains(forbidden), "\(url.lastPathComponent) leaks macOS feature/API \(forbidden)")
            }
            XCTAssertFalse(
                importLines.contains("import MediaCache"),
                "\(url.lastPathComponent) leaks macOS feature/API import MediaCache"
            )
        }

        let verifyScript = repoRoot.appendingPathComponent("scripts/verify-ios-app-shell.sh")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: verifyScript.path), "iOS app shell build gate script is required")
        let rebuild =
            (try? String(contentsOf: repoRoot.appendingPathComponent("scripts/rebuild.sh"), encoding: .utf8)) ?? ""
        XCTAssertTrue(rebuild.contains("-scheme \"$MAC_SCHEME\""), "rebuild.sh must build the macOS app")
        XCTAssertTrue(rebuild.contains("-scheme \"$IOS_SCHEME\""), "rebuild.sh must build the iOS app")
        XCTAssertTrue(
            rebuild.contains("DEVELOPMENT_TEAM=\"$DEVELOPMENT_TEAM\""),
            "rebuild.sh must select the stable Apple development team for macOS signing"
        )
        XCTAssertTrue(rebuild.contains("team_id=\"$(codesign -dvv"))
        XCTAssertTrue(rebuild.contains("[[ \"$team_id\" != \"$DEVELOPMENT_TEAM\" ]]"))
        let sourceVerification = try XCTUnwrap(rebuild.range(of: "verify_mac_app \"$MAC_APP\""))
        let installedAppRemoval = try XCTUnwrap(rebuild.range(of: "rm -rf \"$MAC_DST\""))
        let installedAppCopy = try XCTUnwrap(rebuild.range(of: "cp -R \"$MAC_APP\" \"$MAC_DST\""))
        let installedVerification = try XCTUnwrap(
            rebuild.range(
                of: "verify_mac_app \"$MAC_DST\"",
                range: installedAppCopy.upperBound..<rebuild.endIndex
            )
        )
        XCTAssertLessThan(sourceVerification.lowerBound, installedAppRemoval.lowerBound)
        XCTAssertLessThan(installedAppRemoval.lowerBound, installedAppCopy.lowerBound)
        XCTAssertLessThan(installedAppCopy.lowerBound, installedVerification.lowerBound)
        let projectYAML = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let explicitSchemes = projectYAML.components(separatedBy: "\nschemes:\n").last ?? ""
        XCTAssertTrue(
            explicitSchemes.contains("  EncryptedMemoriesMobile:\n"),
            "project.yml must keep the iOS app scheme consumed by rebuild.sh when explicit schemes are present"
        )
        XCTAssertTrue(
            rebuild.contains("devicectl list devices"),
            "rebuild.sh must detect an available iOS device before installing"
        )
        XCTAssertFalse(rebuild.contains("swift test"), "rebuild.sh is a build/install command, not a test gate")

        let mobileShell = mobileAppSourceFiles()
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(
            mobileShell.contains("import MediaCacheCore"),
            "iOS app must import the shared thumbnail crawl policy module"
        )
        XCTAssertTrue(
            mobileShell.contains("ThumbnailCrawlOrder.newestToOldestFromChronological(crawlItems)"),
            "iOS app must crawl thumbnails newest-to-oldest like macOS"
        )
        XCTAssertFalse(
            mobileShell.contains("feed.startPrefetch(items.map(\\.uid))"),
            "iOS app must not crawl thumbnails in raw timeline order"
        )
    }

    func testMobileShellUsesOneNativeTabOnlyHierarchy() throws {
        let mobileApp = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/EncryptedMemoriesMobileApp.swift"),
            encoding: .utf8
        )
        let mobileTimeline = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileTimelineScreen.swift"),
            encoding: .utf8
        )
        let adaptiveShell = try sourceBlock(
            from: "private struct MobileAdaptiveTabShell: View",
            to: "private struct MobileSearchTabScreen: View",
            in: mobileApp
        )
        let searchTabScreen = try sourceBlock(
            from: "private struct MobileSearchTabScreen: View",
            to: "private struct MobileUnsupportedDeviceView: View",
            in: mobileApp
        )

        XCTAssertTrue(
            mobileApp.contains("MobileAdaptiveTabShell(selection: $selection)")
                && mobileApp.contains(".tabViewStyle(.tabBarOnly)"),
            "iPhone and iPad must share the native tab-only hierarchy without a redundant iPad sidebar toggle"
        )
        XCTAssertTrue(
            mobileApp.contains("surface: .library,") && mobileApp.contains("MobileCollectionsScreen()")
                && mobileApp.contains("MobileMapScreen()")
                && mobileApp.contains("Tab(value: MobileTab.search, role: .search)")
                && mobileApp.contains("surface: .search,")
                && mobileApp.contains(".tabViewSearchActivation(.searchTabSelection)"),
            "the adaptive shell must keep three primary tabs plus the native semantic search surface"
        )
        XCTAssertFalse(adaptiveShell.isEmpty, "the native tab shell source guard must resolve its type boundary")
        XCTAssertFalse(searchTabScreen.isEmpty, "the semantic search source guard must resolve its type boundary")
        XCTAssertFalse(
            adaptiveShell.contains(".searchable(") || adaptiveShell.contains(".smartSearchScopes("),
            "outer TabView search modifiers propagate ordinary top search chrome into non-search tabs"
        )
        XCTAssertTrue(
            searchTabScreen.contains("MobileTimelineScreen(") && searchTabScreen.contains(".searchable(")
                && searchTabScreen.contains(".smartSearchScopes("),
            "the semantic search tab's own navigation content must own its searchable and scope policy"
        )
        XCTAssertEqual(
            mobileApp.components(separatedBy: ".searchable(").count - 1,
            1,
            "the mobile root shell must expose exactly one native search surface"
        )
        XCTAssertFalse(
            mobileApp.contains("--search-tab-diagnostic") || mobileApp.contains("Search-tab baseline"),
            "temporary search diagnostics must not remain reachable in production"
        )
        XCTAssertFalse(
            mobileApp.contains("MobileTab.settings") || mobileApp.contains("MobileSettingsScreen("),
            "Settings must not consume a bottom-tab slot"
        )
        XCTAssertTrue(
            mobileTimeline.contains("MobileSettingsScreen(showsDismissButton: true)")
                && mobileTimeline.contains("person.crop.circle"),
            "the stable library account control must present Settings"
        )
        XCTAssertFalse(
            mobileApp.contains("Image(systemName: \"sidebar.left\")"),
            """
            iPad detail must not add a manual sidebar toggle on top of NavigationSplitView's built-in
            control. Rely on the single native control.
            """
        )
    }

    func testMobileRoutesUseConsistentNativeTitles() throws {
        let contracts = [
            ("iOSApp/MobileTimelineScreen.swift", ".mobileNavigationTitle("),
            ("iOSApp/MobileAlbumsScreen.swift", ".mobileNavigationTitle(String(localized: \"tab.collections\"))"),
            ("iOSApp/MobileAlbumsScreen.swift", ".mobileNavigationTitle(title)"),
            ("iOSApp/MobileMapScreen.swift", ".mobileNavigationTitle(String(localized: \"tab.map\"))"),
            ("iOSApp/MobileMapClusterSeriesScreen.swift", ".mobileNavigationTitle(placeName"),
            ("iOSApp/MobileSettingsScreen.swift", ".mobileNavigationTitle(String(localized: \"tab.settings\"))"),
            ("iOSApp/MobileSettingsScreen.swift", ".mobileNavigationTitle(L10n.string(\"backup.failed_sheet_title\"))"),
            ("iOSApp/MobileSmartSearchScreen.swift", ".mobileNavigationTitle(MLSmartSearchPresentation.productName)"),
            (
                "iOSApp/MobileAlbumSyncScreen.swift",
                ".mobileNavigationTitle(String(localized: \"settings.albumsync_title\"))"
            ),
            (
                "iOSApp/MobileAlbumSyncScreen.swift",
                ".mobileNavigationTitle(L10n.string(\"settings.albumsync_picker_title\"))"
            ),
        ]

        for (relativePath, title) in contracts {
            let source = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
            XCTAssertTrue(source.contains(title), "\(relativePath) must use the shared root title")
            XCTAssertFalse(source.contains(".navigationBarTitleDisplayMode(.large)"))
        }

        let rootChrome = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileRootChrome.swift"), encoding: .utf8
        )
        XCTAssertFalse(rootChrome.contains("ToolbarItem(placement: .topBarLeading)"))
        XCTAssertFalse(rootChrome.contains("ToolbarItem(placement: .title)"))
        XCTAssertTrue(rootChrome.contains(".navigationTitle(isVisible ? title : \"\")"))
        XCTAssertTrue(rootChrome.contains(".toolbarTitleDisplayMode(.inline)"))
        XCTAssertTrue(rootChrome.contains("MobileNavigationItemStyleBridge(style: .browser)"))
        XCTAssertTrue(rootChrome.contains("visibleController.navigationItem.style = style"))
        XCTAssertTrue(rootChrome.contains("belongs(to: visibleController)"))
        XCTAssertFalse(rootChrome.contains(".overlay(alignment: .topLeading)"))
        XCTAssertFalse(rootChrome.contains("rootTitleTopPadding"))
        XCTAssertFalse(rootChrome.contains(".padding(.leading"))
        XCTAssertFalse(rootChrome.contains(".minimumScaleFactor"))

        let iosAppURL = repoRoot.appendingPathComponent("iOSApp")
        let swiftFiles = try FileManager.default.contentsOfDirectory(
            at: iosAppURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" && $0.lastPathComponent != "MobileRootChrome.swift" }
        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                source.contains(".navigationTitle("),
                "\(file.lastPathComponent) must use mobileNavigationTitle so every route shares one native title policy"
            )
        }

        let timeline = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileTimelineScreen.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(timeline.contains("LibraryTitleStatus"))
        XCTAssertTrue(timeline.contains("LibraryActivityBannerOverlay("))
        XCTAssertTrue(timeline.contains("L10n.string(\"library.title_activity\")"))
        XCTAssertTrue(timeline.contains("LibraryConnectivityBannerState"))
        XCTAssertTrue(timeline.contains("L10n.string(\"library.title_offline\")"))
        XCTAssertTrue(timeline.contains("L10n.string(\"library.title_online_restored\")"))
        let mobileApp = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/EncryptedMemoriesMobileApp.swift"),
            encoding: .utf8
        )
        let adaptiveShell = try sourceBlock(
            from: "private struct MobileAdaptiveTabShell: View",
            to: "private struct MobileSearchTabScreen: View",
            in: mobileApp
        )
        let searchTabScreen = try sourceBlock(
            from: "private struct MobileSearchTabScreen: View",
            to: "private struct MobileUnsupportedDeviceView: View",
            in: mobileApp
        )
        XCTAssertTrue(
            mobileApp.contains("Tab(value: MobileTab.search, role: .search)")
                && searchTabScreen.contains(".searchable(\n            text: $searchText")
                && searchTabScreen.contains(".smartSearchScopes(") && !adaptiveShell.contains(".searchable(")
                && !mobileApp.contains(".smartSearchToolbar("),
            "mobile search must stay owned by the search tab's stable navigation content during rotation"
        )
        XCTAssertFalse(timeline.contains(".smartSearchToolbar("))
    }

    func testIOSDeviceBuildsCarryVerifiableSourceProvenance() throws {
        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let infoPlist = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/Info.plist"),
            encoding: .utf8
        )
        let mobileApp = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/EncryptedMemoriesMobileApp.swift"),
            encoding: .utf8
        )
        let rebuild = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/rebuild.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(infoPlist.contains("<key>EncryptedMemoriesBuildCommit</key>"))
        XCTAssertTrue(mobileApp.contains("[BuildProvenance] commit="))
        XCTAssertTrue(rebuild.contains("SOURCE_BUILD_COMMIT=\"$(git rev-parse --short=12 HEAD)\""))
        XCTAssertTrue(rebuild.contains("SOURCE_BUILD_NUMBER=\"$(git rev-list --count HEAD)\""))
        XCTAssertEqual(
            rebuild.components(separatedBy: "CURRENT_PROJECT_VERSION=\"$SOURCE_BUILD_NUMBER\"").count - 1,
            2,
            "signed macOS and iOS builds must expose the same current source build number"
        )
        let fallbackLine =
            project
            .split(separator: "\n")
            .first { $0.contains("CURRENT_PROJECT_VERSION:") }
        let fallbackBuild = fallbackLine.flatMap { line -> Int? in
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { return nil }
            return Int(fields[1].trimmingCharacters(in: CharacterSet(charactersIn: " \\\"")))
        }
        XCTAssertGreaterThan(
            fallbackBuild ?? 0,
            1,
            "ad-hoc Xcode builds must not display the placeholder Build 1"
        )
        XCTAssertTrue(rebuild.contains("Refusing to install iOS provenance"))
        XCTAssertTrue(rebuild.contains("xcrun dwarfdump --uuid"))
    }

    func testMobileViewerResolvesTheSharedMetadataLocationTitle() throws {
        let viewer = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobilePhotoViewer.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(viewer.contains("ViewerTitleMetadataCoordinator("))
        XCTAssertTrue(viewer.contains("placeNameResolver: NativePlaceNameResolver.shared"))
        XCTAssertTrue(viewer.contains("locationName: titleMetadataState.resolution?.placeName"))
        XCTAssertTrue(viewer.contains("filename: metadataLoadState.metadata?.filename"))
    }

    func testBackupRemoteDeletionInfoUsesTheSharedNeutralSymbolColor() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/UploadFeature/BackupRemoteDeletionInfoButton.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".foregroundStyle(.secondary)"))
        XCTAssertFalse(source.contains(".foregroundStyle(.purple)"))

        for relativePath in ["App/Views/SettingsView.swift", "iOSApp/MobileSettingsScreen.swift"] {
            let host = try String(
                contentsOf: repoRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(
                host.contains("VStack(alignment: .trailing, spacing: 8)"),
                "\(relativePath) must keep backup actions and the remote-deletion info control in a stable trailing column"
            )
            XCTAssertTrue(
                host.contains("BackupRemoteDeletionInfoButton(message: skipped)"),
                "\(relativePath) must expose the shared remote-deletion explanation"
            )
        }
    }

    func testPlatformAppsUseSharedProtonDriveBackend() {
        let projectYML =
            (try? String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)) ?? ""
        let macTarget = targetBlock(named: "EncryptedMemories", in: projectYML)
        let mobileTarget = targetBlock(named: "EncryptedMemoriesMobile", in: projectYML)
        XCTAssertTrue(
            macTarget.contains("product: ProtonDriveBackend"), "macOS app must use the shared Proton backend product")
        XCTAssertTrue(
            mobileTarget.contains("product: ProtonDriveBackend"), "iOS app must use the shared Proton backend product")
        XCTAssertFalse(macTarget.contains("product: ProtonDriveSDK"), "macOS app must not wire the Drive SDK directly")
        XCTAssertFalse(mobileTarget.contains("product: ProtonDriveSDK"), "iOS app must not wire the Drive SDK directly")

        let manifest =
            (try? String(
                contentsOf: repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Package.swift"),
                encoding: .utf8
            )) ?? ""
        XCTAssertTrue(
            manifest.contains(".library(name: \"ProtonDriveBackend\", targets: [\"ProtonDriveBackend\"])"),
            "ProtonDriveBackend must be a shared package product"
        )
        XCTAssertTrue(
            manifest.contains(".product(name: \"ProtonDriveSDK\", package: \"ProtonDriveSDK\")"),
            "Only the shared backend package target should depend on ProtonDriveSDK"
        )

        for url in appSourceFiles() + mobileAppSourceFiles() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            XCTAssertFalse(
                text.contains("import ProtonDriveSDK"), "\(url.lastPathComponent) must not import ProtonDriveSDK")
            XCTAssertFalse(
                text.contains("DriveSDKBridge("),
                "\(url.lastPathComponent) must not instantiate the SDK bridge directly")
            XCTAssertFalse(
                text.contains("MobileSyntheticThumbnailLoader"),
                "\(url.lastPathComponent) must not use fake mobile thumbnails")
            XCTAssertFalse(
                text.contains("demoItems"), "\(url.lastPathComponent) must not use fake mobile timeline items")
        }

        let appSwiftFiles = appSourceFiles().map(\.path)
        XCTAssertFalse(
            appSwiftFiles.contains { $0.contains("/App/Drive/") },
            "SDK/HTTP backend Swift files must live in ProtonDriveBackend, not App/Drive"
        )
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

    func testAlbumSyncRefreshAndChangeObservationStayShared() throws {
        let controller = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoLibraryBackupAdapter/AlbumSyncController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(controller.contains("private let changeMonitor: PhotoLibraryChangeMonitor"))
        XCTAssertTrue(controller.contains("changeMonitor.startObserving"))
        XCTAssertTrue(controller.contains("scheduleChangeDrivenSync()"))
        XCTAssertTrue(controller.contains("syncSelected()"))
        XCTAssertTrue(controller.contains("setRemoteAlbumsChangedHandler"))
        XCTAssertTrue(controller.contains("onRemoteAlbumsChanged?()"))

        let appModel = try String(contentsOf: repoRoot.appendingPathComponent("App/AppModel.swift"), encoding: .utf8)
        XCTAssertTrue(appModel.contains("private(set) var albumCatalogRevision"))
        XCTAssertTrue(appModel.contains("albumSync.setRemoteAlbumsChangedHandler"))

        let mainView = try String(
            contentsOf: repoRoot.appendingPathComponent("App/Views/MainView.swift"), encoding: .utf8)
        XCTAssertTrue(mainView.contains(".task(id: model.albumCatalogRevision) { await loadAlbums() }"))
        XCTAssertTrue(mainView.contains("@MainActor private func performRemoteLibraryRefresh()"))
        XCTAssertTrue(
            mainView.contains("await loadAlbums()"),
            "the shared remote-library poll must refresh the macOS album catalog too")

        let mobileModel = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileLibraryModel.swift"), encoding: .utf8)
        XCTAssertTrue(mobileModel.contains("private(set) var albumCatalogRevision"))
        XCTAssertTrue(mobileModel.contains("albumSync.setRemoteAlbumsChangedHandler"))
        let mobileRemoteRefresh = try sourceBlock(
            from: "private func performLibraryRefresh(",
            to: "private func apply(_ event: LibraryLoadEvent)",
            in: mobileModel
        )
        XCTAssertTrue(
            mobileRemoteRefresh.contains("albumCatalogRevision &+= 1"),
            "the shared remote-library poll must invalidate the iOS/iPadOS album catalog too")
        XCTAssertTrue(
            mobileRemoteRefresh.contains("refreshLibrarySources()"),
            "the shared remote-library poll must refresh additional source inventories too")

        let mobileAlbums = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileAlbumsScreen.swift"), encoding: .utf8)
        XCTAssertTrue(
            mobileAlbums.contains(
                "AlbumsReloadKey(backendReady: model.backend != nil, revision: model.albumCatalogRevision)"))
    }

    func testPhotoBackupIdempotencyGuardsStayLoadBearing() throws {
        let monitor = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoLibraryBackupAdapter/PhotoLibraryChangeMonitor.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(monitor.contains("public func prepareChanges() -> PreparedChangeSet"))
        XCTAssertTrue(monitor.contains("public func commit(_ prepared: PreparedChangeSet)"))
        XCTAssertFalse(
            monitor.contains("func consumeChanges()"),
            "PhotoKit change tokens must never be consumed before scan/enqueue durability is proven")

        let controller = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoLibraryBackupAdapter/PhotoLibraryBackupController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(controller.contains("let preparedChanges = await Self.prepareChangesOffMainActor(monitor)"))
        XCTAssertTrue(
            controller.contains("monitor.prepareChanges()"),
            "the off-main helper must still prepare the durable PhotoKit change set")
        XCTAssertTrue(controller.contains("monitor.commit(preparedChanges)"))
        XCTAssertTrue(controller.contains("L10n.string(\"backup.error_execution_lock_unavailable\")"))
        XCTAssertFalse(
            controller.contains("degrade to unlocked"),
            "execution-lock failure must be fail-closed, not best-effort")
        XCTAssertTrue(
            controller.contains("changes.changedIdentifiers + changes.deletedIdentifiers"),
            "targeted PhotoKit changes must include deletes so the catalog cannot stay stale")
        XCTAssertTrue(
            controller.contains("pendingSyncAfterStop = true"),
            "re-enabling after disabling during a stop must schedule a fresh pass instead of inheriting pause")
        XCTAssertTrue(
            controller.contains("monitor.stopObserving()"),
            "disabling photo backup must tear down live change observation")
        XCTAssertTrue(
            controller.contains("if shouldRestart { syncNow() }"),
            "the queued re-enable pass must run after the previous stop fully settles")
        XCTAssertTrue(controller.contains("owner != .manual"))
        XCTAssertTrue(
            controller.contains("runtimeIssue(for: .remoteIndexPreparation)?.nextAttemptAt"),
            "automatic lifecycle/change launches must honor persisted remote-index backoff")
        XCTAssertTrue(
            controller.contains("startSync(owner: .manual)"),
            "only explicit user retry may bypass a persisted automatic retry date")

        let runner = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/UploadCore/Backup/BackupSyncRunner.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            runner.contains("queue.claimRunnable(limit: claimLimit"),
            "drainers must atomically reserve rows in Core before processing")
        XCTAssertFalse(
            runner.contains("queue.nextRunnable(limit: configuration.batchSize)"),
            "the runner must not drain from a read-only runnable query")
        XCTAssertTrue(
            runner.contains("public func stop() async"),
            "stopping a backup must join cancellation and upload settlement")
        XCTAssertTrue(
            runner.contains("await join.cancelAndJoin()"),
            "timeout, task cancellation, and stop must share the upload join")
        XCTAssertFalse(
            runner.contains("Task { await uploader.cancel(token: request.cancellationToken) }"),
            "native cancellation must not be launched as an unjoined fire-and-forget task")
    }

    func testPhotoBackupPermissionAndBackgroundDeclarations() throws {
        // iOS: usage description + BG processing declarations must stay consistent with the
        // registered task identifier.
        let infoData = try Data(contentsOf: repoRoot.appendingPathComponent("iOSApp/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertNotNil(
            info["NSPhotoLibraryUsageDescription"],
            "photo backup needs a usage description on iOS")
        let identifiers = try XCTUnwrap(info["BGTaskSchedulerPermittedIdentifiers"] as? [String])
        XCTAssertEqual(identifiers, ["at.oncloud.encryptedmemories.photo-backup.processing"])
        let modes = try XCTUnwrap(info["UIBackgroundModes"] as? [String])
        XCTAssertTrue(modes.contains("processing"))
        XCTAssertFalse(
            modes.contains("audio") || modes.contains("location") || modes.contains("voip"),
            "no keep-alive background-mode abuse")

        let backgroundCoordinator =
            (try? String(
                contentsOf: repoRoot.appendingPathComponent("iOSApp/PhotoBackupBackgroundCoordinator.swift"),
                encoding: .utf8
            )) ?? ""
        XCTAssertTrue(
            backgroundCoordinator.contains("at.oncloud.encryptedmemories.photo-backup.processing"),
            "the registered processing-task identifier must match Info.plist")
        XCTAssertFalse(
            backgroundCoordinator.contains("BGContinuedProcessingTask"),
            "backup must not create a system Live Activity")
        XCTAssertFalse(
            backgroundCoordinator.contains("photo-backup.continued"),
            "the retired continued-processing identifier must not return")
        XCTAssertFalse(
            backgroundCoordinator.contains("try? BGTaskScheduler.shared.submit"),
            "background task submission failures must not be silently discarded")
        XCTAssertTrue(
            backgroundCoordinator.contains("completion.finish(success: !attempt.didExpire && !Task.isCancelled)"),
            "background completion must remain owned by the settled work task")
        XCTAssertFalse(
            backgroundCoordinator.contains("completion.finish(success: controller != nil)"),
            "expiration must not complete the background task before catch-up settles")
        XCTAssertFalse(
            backgroundCoordinator.contains(
                "task.expirationHandler = { [weak self] in\n            completion.finish(success: false)"),
            "routine iOS window expiration must not immediately render as a failed backup")
        XCTAssertTrue(backgroundCoordinator.contains("func applicationDidBecomeActive"))
        XCTAssertTrue(
            backgroundCoordinator.contains("processingIssue = nil"),
            "foreground execution must clear stale discretionary scheduler errors")
        let processingHandler = try XCTUnwrap(backgroundCoordinator.range(of: "private func handleProcessingTask"))
        let processingSource = backgroundCoordinator[processingHandler.lowerBound...]
        let catchUp = try XCTUnwrap(processingSource.range(of: "await controller.backgroundCatchUp"))
        let completion = try XCTUnwrap(
            processingSource.range(of: "completion.finish(success: !attempt.didExpire && !Task.isCancelled)")
        )
        XCTAssertLessThan(
            catchUp.lowerBound, completion.lowerBound,
            "background completion must follow the settled catch-up pass")
        let expiration = try XCTUnwrap(processingSource.range(of: "task.expirationHandler = { [weak self] in"))
        let expirationSource = processingSource[expiration.lowerBound...]
        XCTAssertTrue(
            expirationSource.contains("stopSync(runID:"),
            "expiration must stop only the run owned by this background attempt")
        XCTAssertFalse(
            expirationSource.contains("controller?.stopSync()"),
            "background expiration must not stop an unrelated foreground run")
        XCTAssertTrue(
            expirationSource.contains("scheduleProcessingCatchUp"),
            "expiration must schedule the next background opportunity")
        XCTAssertFalse(
            expirationSource.contains("completion.finish"),
            "expiration must let the work task own completion")
        XCTAssertTrue(
            backgroundCoordinator.contains("stopScheduling(detachController: false)"),
            "pause must retain the shared controller for a later background launch")
        let resubmission = try XCTUnwrap(
            backgroundCoordinator.range(
                of: "scheduleProcessingCatchUp()", range: processingHandler.lowerBound..<backgroundCoordinator.endIndex)
        )
        let controllerWait = try XCTUnwrap(
            backgroundCoordinator.range(
                of: "await self.waitForController()",
                range: processingHandler.lowerBound..<backgroundCoordinator.endIndex)
        )
        XCTAssertLessThan(
            resubmission.lowerBound, controllerWait.lowerBound,
            "a consumed processing request must be replaced before fallible work begins")

        let mobileSettings = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileSettingsScreen.swift"), encoding: .utf8
        )
        XCTAssertFalse(
            mobileSettings.contains("String(localized: \"backup.failed_sheet_"),
            "package-owned retry-sheet strings must resolve through PhotosCore L10n, not Bundle.main"
        )
        XCTAssertTrue(mobileSettings.contains("L10n.string(\"backup.failed_sheet_"))
        XCTAssertTrue(
            mobileSettings.contains("await controller.resumeBackup()"),
            "the mobile resume action must clear the durable user pause")
        XCTAssertTrue(
            mobileSettings.contains("backupResumed(controller: controller)"),
            "resume must schedule another background opportunity")
        XCTAssertFalse(
            mobileSettings.contains("settings.photos_backup_resume\", defaultValue:"),
            "resume wording must come from the translated string catalog")

        let macSettings = try String(
            contentsOf: repoRoot.appendingPathComponent("App/Views/SettingsView.swift"), encoding: .utf8
        )
        XCTAssertTrue(macSettings.contains("if controller.isUserPaused"))
        XCTAssertTrue(
            macSettings.contains("await controller.resumeBackup()"),
            "macOS must make a durable pause resumable")
        XCTAssertTrue(
            macSettings.contains("controller.pauseBackup()"),
            "macOS Pause must suppress automatic restarts, not merely stop one pass")
        XCTAssertTrue(
            macSettings.contains("statusIcon(display)"),
            "macOS and iOS must use the same backup status icon vocabulary")
        XCTAssertFalse(
            macSettings.contains("Color.clear.frame(height: 4)"),
            "an absent backup fraction must not create an empty macOS Form row with separators")
        XCTAssertTrue(
            macSettings.contains("folderBackupFullDiskAccessIntroduced"),
            "the first macOS folder selection must remember its access setup")
        XCTAssertTrue(
            macSettings.contains("Privacy_AllFiles"),
            "the first macOS folder selection must open Full Disk Access settings")

        let folderController = try String(
            contentsOf: repoRoot.appendingPathComponent("App/FolderBackupController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            folderController.contains("catch let error as FolderEnumerationError"),
            "macOS folder backup must preserve typed enumeration failures")
        XCTAssertTrue(
            folderController.contains("error.requiresRootAccessRenewal(for: root)"),
            "root folder access failures must mark the bookmark for renewal")
        XCTAssertTrue(
            folderController.contains("Self.localizedFolderError"),
            "folder enumeration failures must use user-facing localized wording")
        XCTAssertFalse(
            folderController.contains("reportSyncMessage(error.localizedDescription)"),
            "folder enumeration failures must not expose raw technical text")
        XCTAssertTrue(
            folderController.contains("hasFolderEnumerationFailure"),
            "a partial folder scan must retain a run-level failure after the queue prefix drains")
        XCTAssertTrue(
            folderController.contains("Self.statusAfterFolderEnumerationFailure"),
            "a partial folder scan must not project the drained prefix as completed")

        // macOS: usage description via project.yml.
        let projectYML = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(
            projectYML.contains("INFOPLIST_KEY_NSPhotoLibraryUsageDescription"),
            "photo backup needs a usage description on macOS")
    }

    func testPhotoBackupRetiresLateTargetedWorkBeforeReleasingExecutionLock() throws {
        let controller = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoLibraryBackupAdapter/PhotoLibraryBackupController.swift"
            ),
            encoding: .utf8
        )
        let finishStart = try XCTUnwrap(controller.range(of: "private func finishSync(runID: String) async"))
        let finishTail = controller[finishStart.lowerBound...]
        let retirement = try XCTUnwrap(finishTail.range(of: "await retireInstantWorkTask()"))
        let release = try XCTUnwrap(finishTail.range(of: "lockStore?.release(runID: runID)"))
        XCTAssertLessThan(
            retirement.lowerBound,
            release.lowerBound,
            "the pass must cancel and bounded-join targeted catalog work before releasing its execution lock"
        )

        XCTAssertTrue(controller.contains("private func retireInstantWorkTask() async"))
        XCTAssertTrue(
            controller.contains("PhotoLibraryBackupController.instantWorkRetirementTimeout"),
            "expiration retirement must use a bounded wait instead of an unbounded task join"
        )
    }

    func testFolderBackupCancellationStopsBeforeDrainAndJoinsRunner() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("App/FolderBackupController.swift"),
            encoding: .utf8
        )
        let cancellation = try XCTUnwrap(source.range(of: "catch is CancellationError"))
        let typedFailure = try XCTUnwrap(source.range(of: "catch let error as FolderEnumerationError"))
        let genericFailure = try XCTUnwrap(
            source.range(of: "} catch {", range: typedFailure.upperBound..<source.endIndex))
        XCTAssertLessThan(
            cancellation.lowerBound,
            typedFailure.lowerBound,
            "folder cancellation must be handled before typed enumeration failures"
        )
        XCTAssertLessThan(
            typedFailure.lowerBound,
            genericFailure.lowerBound,
            "typed enumeration failures must remain distinct from generic failures"
        )

        let drain = try XCTUnwrap(source.range(of: "runner.runUntilDrained"))
        let drainGuard = try XCTUnwrap(
            source.range(of: "guard !Task.isCancelled else {", range: cancellation.upperBound..<drain.lowerBound))
        XCTAssertLessThan(
            drainGuard.lowerBound,
            drain.lowerBound,
            "folder cancellation must skip the drain"
        )
        XCTAssertTrue(source.contains("private var runnerStopTask: Task<Void, Never>?"))
        XCTAssertTrue(source.contains("await stopTask?.value"))
        XCTAssertTrue(source.contains("runnerStopTask == nil"))
    }

    func testMobileFailureAndAccessibilityContractsRemainExplicit() throws {
        let map = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileMapScreen.swift"),
            encoding: .utf8
        )
        let failedCase = try XCTUnwrap(map.range(of: "case .failed:"))
        let completedCase = try XCTUnwrap(map.range(of: "case .completed:"))
        let failedBody = map[failedCase.lowerBound..<completedCase.lowerBound]
        XCTAssertTrue(failedBody.contains("Button(L10n.string(\"action.retry\"))"))
        XCTAssertTrue(failedBody.contains("model.restartLocationCrawlIfNeeded()"))

        let viewer = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobilePhotoViewer.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(viewer.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(viewer.contains("MobileViewerMotionPolicy.animation"))
        XCTAssertTrue(viewer.contains("MobileViewerMotionPolicy.duration"))

        let catalogData = try Data(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/Localizable.xcstrings")
        )
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertEqual(localizedValue("settings.cache_size", locale: "en", strings: strings), "Thumbnail Cache Size")
        XCTAssertEqual(localizedValue("settings.cache_size", locale: "de", strings: strings), "Thumbnail-Cache-Größe")
        XCTAssertEqual(localizedValue("settings.clear_cache", locale: "en", strings: strings), "Clear Thumbnail Cache")
        XCTAssertEqual(localizedValue("settings.clear_cache", locale: "de", strings: strings), "Thumbnail-Cache leeren")
    }

    func testMobileRetryRetiresOwnersBeforePreservingAndRestartingTheVisibleSnapshot() throws {
        let model = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileLibraryModel.swift"),
            encoding: .utf8
        )
        let retryStart = try XCTUnwrap(model.range(of: "func retry() async"))
        let retryTail = model[retryStart.lowerBound...]
        let retirement = try XCTUnwrap(retryTail.range(of: "await self.retireForRetry()"))
        let replacement = try XCTUnwrap(
            retryTail.range(of: "self.start(session: session, store: store, preserveVisibleSnapshot: true)")
        )
        XCTAssertLessThan(
            retirement.lowerBound,
            replacement.lowerBound,
            "a retry must join every old owner before it creates a replacement owner graph"
        )
        XCTAssertTrue(
            model.contains("if !preserveVisibleSnapshot"),
            "same-account retry must retain a still-usable visible snapshot"
        )
        for joinedTask in [
            "await activeTransitionTask?.value",
            "await activeLoadTask?.value",
            "await activePrefetchStartTask?.value",
            "await activeFavoriteLoadTask?.value",
            "await activeThumbnailUpdateTask?.value",
        ] {
            XCTAssertTrue(
                model.contains(joinedTask),
                "transient retry must join \(joinedTask) before facade replacement"
            )
        }
    }

    private func localizedValue(
        _ key: String,
        locale: String,
        strings: [String: Any]
    ) -> String? {
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let localization = localizations?[locale] as? [String: Any]
        let stringUnit = localization?["stringUnit"] as? [String: Any]
        return stringUnit?["value"] as? String
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

    func testPlatformAppsUseSharedAuthLifecycleController() {
        let appModel =
            (try? String(
                contentsOf: repoRoot.appendingPathComponent("App/AppModel.swift"),
                encoding: .utf8
            )) ?? ""
        XCTAssertTrue(appModel.contains("ProtonAuthController"), "macOS app must compose the shared auth lifecycle")
        XCTAssertFalse(
            appModel.contains("ProtonForkAuthenticator()"),
            "macOS app must not instantiate the concrete fork authenticator directly"
        )
        XCTAssertTrue(
            appModel.contains("ProtonForkAuthenticator(config: .externalDriveEncryptedMemories)"),
            "macOS app must inject the documented Proton API client identity explicitly"
        )

        for url in mobileAppSourceFiles() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            XCTAssertFalse(
                text.contains("ProtonForkAuthenticator()"),
                "\(url.lastPathComponent) must not instantiate the concrete fork authenticator directly"
            )
        }
        let mobileShell = mobileAppSourceFiles()
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(mobileShell.contains("ProtonAuthController"), "iOS app must compose the shared auth lifecycle")
        XCTAssertTrue(
            mobileShell.contains("ProtonForkAuthenticator(config: .externalDriveEncryptedMemories)"),
            "iOS app must inject the documented Proton API client identity explicitly"
        )
    }

    func testPlatformAppsUseManagedWebAuthenticationSession() throws {
        let sharedSession = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonAuth/ManagedWebAuthenticationSession.swift"
            ),
            encoding: .utf8
        )
        let macModel = try String(
            contentsOf: repoRoot.appendingPathComponent("App/AppModel.swift"),
            encoding: .utf8
        )
        let mobileModel = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileSessionModel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(sharedSession.contains("ASWebAuthenticationSession"))
        XCTAssertTrue(sharedSession.contains("presentationContextProvider"))
        XCTAssertTrue(macModel.contains("ManagedWebAuthenticationSession()"))
        XCTAssertTrue(mobileModel.contains("ManagedWebAuthenticationSession()"))
        XCTAssertFalse(macModel.contains("NSWorkspace.shared.open(url)"))
        XCTAssertFalse(mobileModel.contains("UIApplication.shared.open(url)"))
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

    func testVisibleProductNameStaysCentralized() throws {
        let projectYML = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let macTarget = targetBlock(named: "EncryptedMemories", in: projectYML)
        let mobileTarget = targetBlock(named: "EncryptedMemoriesMobile", in: projectYML)
        XCTAssertTrue(macTarget.contains("APP_DISPLAY_NAME: \"Encrypted Memories\""))
        XCTAssertTrue(mobileTarget.contains("APP_DISPLAY_NAME: \"Memories\""))
        XCTAssertTrue(projectYML.contains("PRODUCT_NAME: \"Encrypted Memories\""))
        XCTAssertTrue(projectYML.contains("INFOPLIST_KEY_CFBundleName: $(PRODUCT_NAME)"))
        XCTAssertTrue(projectYML.contains("INFOPLIST_KEY_CFBundleDisplayName: $(APP_DISPLAY_NAME)"))

        let infoData = try Data(contentsOf: repoRoot.appendingPathComponent("iOSApp/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "$(APP_DISPLAY_NAME)")

        let brandSource = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotosCore/ProductBrand.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(brandSource.contains("brand.product_name"))

        for relativePath in [
            "App/Views/LoginView.swift",
            "iOSApp/MobileLoginView.swift",
            "iOSApp/MobileLibraryStateViews.swift",
            "iOSApp/MobileSettingsScreen.swift",
            "iOSApp/EncryptedMemoriesMobileApp.swift",
        ] {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
            XCTAssertTrue(
                text.contains("ProductBrand.displayName"),
                "\(relativePath) must use the centralized visible product name")
        }
    }

    func testLoginBrandMarksUseSharedBrandingAsset() throws {
        let brandMark = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/DesignSystemCore/BrandLogo.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(brandMark.contains("Image(\"EncryptedMemoriesMono\", bundle: .module)"))
        XCTAssertTrue(brandMark.contains("public struct MemoriesBrandMark"))

        let macLogin = try String(
            contentsOf: repoRoot.appendingPathComponent("App/Views/LoginView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(macLogin.contains("MemoriesBrandMark(height: 84)"))
        XCTAssertFalse(
            macLogin.contains("ProtonColor.backgroundNorm.ignoresSafeArea()"),
            "macOS login content must use the persistent library-cover backdrop")
        XCTAssertFalse(
            macLogin.contains("photo.stack.fill"),
            "macOS login must not fall back to a generic SF Symbol for the product logo")

        for (path, height) in [
            ("iOSApp/MobileLoginView.swift", 72),
            ("iOSApp/MobileLibraryStateViews.swift", 40),
            ("iOSApp/MobileSettingsScreen.swift", 28),
        ] {
            let mobileBrand = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(mobileBrand.contains("MemoriesBrandMark(height: \(height))"))
            XCTAssertFalse(
                mobileBrand.contains("Image(\"BrandLogo\")"),
                "mobile screens must use the package-owned branding source, not an app-local copy")
        }
    }

    func testDebugLogUsesSandboxCompatibleLibraryDirectory() {
        let debugLog =
            (try? String(
                contentsOf: repoRoot.appendingPathComponent(
                    "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DebugLog.swift"),
                encoding: .utf8
            )) ?? ""
        XCTAssertTrue(debugLog.contains(".libraryDirectory"), "debug logging must stay inside the app container")
        XCTAssertFalse(
            debugLog.contains("/tmp/encryptedmemories.log"), "sandboxed app must not hard-code /tmp for debug logs")
    }

    func testMobileLoadingMarkAndBackgroundLeaveAsOneCover() throws {
        let sharedCover = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/DesignSystemCore/LibraryLoadingCover.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            sharedCover.contains("public struct LibraryLoadingCover"),
            "loading-cover composition must have one universal implementation")
        XCTAssertTrue(sharedCover.contains("LoadingMark()"))
        XCTAssertTrue(sharedCover.contains("accessibilityReduceTransparency"))
        XCTAssertTrue(sharedCover.contains("accessibilityReduceMotion"))
        XCTAssertTrue(sharedCover.contains("LibraryLoadingCoverMetrics.fadeDuration"))
        XCTAssertTrue(
            sharedCover.contains(".ignoresSafeArea()"),
            "the full-window loading mark must not move when platform toolbar insets mount")
        XCTAssertTrue(
            sharedCover.contains("LibraryActivityBanner(message: activityMessage"),
            "the shared launch cover must explain ongoing library work below the brand mark")
        XCTAssertFalse(
            sharedCover.contains("LinearGradient("),
            "the full-window loading material must stay uniform until the toolbar frost appears")

        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileLibraryStateViews.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("LibraryLoadingCover("),
            "iOS must host the shared cover instead of copying its composition")
        XCTAssertTrue(
            source.contains("MobileFrostedBackdrop(isActive: isActive)"),
            "the initial grid must remain visible through native adaptive material")
        XCTAssertFalse(
            source.contains("RoundedRectangle(cornerRadius: 28"),
            "the launch mark should float directly in the full-frame material")
        XCTAssertTrue(
            source.contains("effect = isActive ? UIBlurEffect") && source.contains("UIView.animate("),
            "the blur must animate its native effect rather than alpha-fading an effect view")

        let macApp = try String(
            contentsOf: repoRoot.appendingPathComponent("App/EncryptedMemoriesApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            macApp.contains("LibraryLoadingCover("),
            "macOS must host the same shared cover")
        XCTAssertTrue(
            macApp.contains("LibraryFrostedBackdrop(isActive: isActive)"),
            "macOS must inject only its native material adapter")
        XCTAssertTrue(
            macApp.contains("showsLoadingContent: displayedPurpose != .authentication"),
            "login and library preparation must share one persistent frosted cover")
        XCTAssertTrue(
            macApp.contains("if visible, displayedPurpose == .authentication"),
            "only the centered content should change when authentication finishes")
        XCTAssertTrue(
            macApp.contains(".windowStyle(.hiddenTitleBar)"),
            "the macOS scene must let its behind-window material reach through the title-bar region")
        XCTAssertTrue(
            macApp.contains(".toolbarVisibility(visible ? .hidden : .automatic, for: .windowToolbar)"),
            "the native window toolbar must stay absent until the shared cover dissolves")
        XCTAssertFalse(
            macApp.contains("window.isOpaque = false") || macApp.contains("window.backgroundColor = .clear"),
            "do not split launch-window presentation between SwiftUI and an imperative AppKit workaround")
        let macBackdrop = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/DesignSystemAppKitAdapter/LoadingVeil.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            macBackdrop.contains("blendingMode = .behindWindow"),
            "the macOS launch material must blur the desktop and other windows")

        let timeline = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileTimelineScreen.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            timeline.contains(".accessibilityHidden(!launchChromeVisible || showsLibraryLoadingCover)"),
            "the mounted grid must not remain accessible behind the launch cover")
        XCTAssertTrue(
            timeline.contains("duration: LibraryLoadingCoverMetrics.fadeDuration"),
            "mobile toolbar content must fade in during the same transition as the loading cover")
        let mobileApp = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/EncryptedMemoriesMobileApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            mobileApp.contains("MobileLibraryLoadingView("),
            "the launch material must live above the complete adaptive navigation shell")
        XCTAssertTrue(
            mobileApp.contains(".libraryActivityTransition("),
            "the launch and grid activity pills must share one geometry transition")

        let gridHost = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/TimelineUIKitFeature/UIKitTimelineGridHost.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(gridHost.contains("contentGeneration &+= 1"))
        XCTAssertTrue(
            gridHost.contains("self.contentGeneration == generation"),
            "a deferred cached-frame callback must not acknowledge replacement UIDs")
    }

    func testVendoredThumbnailEnumerationReleasesSwiftContinuationOnCancellation() throws {
        let sdkRoot = repoRoot.appendingPathComponent("Vendor/sdk-swift/Sources")
        let manager = try String(
            contentsOf: sdkRoot.appendingPathComponent("FileOperations/Downloads/DownloadThumbnailsManager.swift"),
            encoding: .utf8
        )
        let handler = try String(
            contentsOf: sdkRoot.appendingPathComponent("Plumbing/SDKRequestHandler.swift"),
            encoding: .utf8
        )
        let boxedContinuation = try String(
            contentsOf: sdkRoot.appendingPathComponent("Plumbing/BoxedContinuation.swift"),
            encoding: .utf8
        )
        let thumbnailCallback = try String(
            contentsOf: sdkRoot.appendingPathComponent("FileOperations/Downloads/cThumbnailEnumerationCallback.swift"),
            encoding: .utf8
        )
        let cancellationSource = try String(
            contentsOf: sdkRoot.appendingPathComponent("CancellationTokenSource.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(manager.contains("SDKRequestHandler.sendCancellable("))
        XCTAssertTrue(manager.contains("requestCancellation: activeDownload.requestCancellation"))
        XCTAssertTrue(handler.contains("CallbackHandleRegistry.shared.cancel(handle)"))
        XCTAssertTrue(handler.contains("registryBacked: true"))
        XCTAssertTrue(handler.contains("sdkResponseCallbackWithRegistryHandle"))
        XCTAssertTrue(boxedContinuation.contains("RegistryCancellable"))
        XCTAssertTrue(boxedContinuation.contains("CancellationError()"))
        XCTAssertTrue(thumbnailCallback.contains("CallbackHandleRegistry.shared.get"))
        XCTAssertFalse(
            thumbnailCallback.contains("Unmanaged"),
            "late thumbnail callbacks must use registry IDs, never retained raw pointers")
        XCTAssertTrue(
            cancellationSource.contains("freeGate.task"),
            "native cancellation-token free must remain one-shot and awaitable")
    }

    func testVendoredStorageStreamsUseNativeDisposeContract() throws {
        let sdkRoot = repoRoot.appendingPathComponent("Vendor/sdk-swift/Sources/Client/ProtonDriveClient/Networking")
        let stream = try String(
            contentsOf: sdkRoot.appendingPathComponent("Model/BoxedDownloadStream.swift"),
            encoding: .utf8
        )
        let responseProcessor = try String(
            contentsOf: sdkRoot.appendingPathComponent("HttpClientResponseProcessor.swift"),
            encoding: .utf8
        )
        let driveClient = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Vendor/sdk-swift/Sources/Client/ProtonDriveClient/ProtonDriveClient.swift"),
            encoding: .utf8
        )
        let photosClient = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Vendor/sdk-swift/Sources/Client/EncryptedMemoriesClient/EncryptedMemoriesClient.swift"),
            encoding: .utf8
        )
        let registryTests = try String(
            contentsOf: repoRoot.appendingPathComponent("Vendor/sdk-swift/Tests/CallbackHandleRegistryTests.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(responseProcessor.contains("cCompatibleHttpResponseDispose"))
        XCTAssertTrue(responseProcessor.contains("CallbackHandleRegistry.shared.remove(bindingsHandle)"))
        XCTAssertTrue(driveClient.contains("responseContentDisposeAction"))
        XCTAssertTrue(photosClient.contains("responseContentDisposeAction"))
        XCTAssertTrue(registryTests.contains("responseDisposeRemovesOwnerManagedHandleExactlyOnce"))
        XCTAssertFalse(
            stream.contains("bufferedByte = nextByte"),
            "the removed lookahead workaround must not coexist with explicit native disposal")
        XCTAssertFalse(
            responseProcessor.contains("if result.reachedEnd"),
            "stream lifetime must follow the native dispose callback, not inferred buffer length")
    }

    func testMacAppKeepsSingleInstanceLaunchGuard() {
        let app =
            (try? String(
                contentsOf: repoRoot.appendingPathComponent("App/EncryptedMemoriesApp.swift"),
                encoding: .utf8
            )) ?? ""
        let guardSource =
            (try? String(
                contentsOf: repoRoot.appendingPathComponent("App/SingleInstanceGuard.swift"),
                encoding: .utf8
            )) ?? ""

        XCTAssertTrue(
            app.contains("@NSApplicationDelegateAdaptor(EncryptedMemoriesAppDelegate.self)"),
            "macOS app must install its process-level launch guard before creating windows"
        )
        XCTAssertTrue(app.contains("singleInstanceGuard.acquire()"))
        XCTAssertTrue(app.contains("NSApp.terminate(nil)"), "duplicate launches must exit immediately")

        XCTAssertTrue(guardSource.contains("flock("), "single-instance guard must use a real process lock")
        XCTAssertTrue(guardSource.contains("LOCK_EX | LOCK_NB"), "duplicate launches must never block startup")
        XCTAssertTrue(
            guardSource.contains(".applicationSupportDirectory"),
            "lock file must stay sandbox-compatible"
        )
    }

    /// Backup must keep the display awake while actively running and release it on every exit path.
    /// The idle-timer hook is injectable (UIKit stays out of the shared adapter); the controller calls
    /// it with `isSyncing` at every transition so the host (iOS) can toggle the idle timer and macOS
    /// can leave the default no-op.
    func testBackupControllerManagesIdleTimerViaInjectableHook() throws {
        let controller = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoLibraryBackupAdapter/PhotoLibraryBackupController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            controller.contains("idleTimerHook: ((Bool) -> Void)?"),
            "controller must expose an injectable idle-timer hook (no UIKit in the shared adapter)")
        XCTAssertTrue(
            controller.contains("updateIdleTimerIfNeeded()"), "controller must have a single idle-timer chokepoint")
        XCTAssertTrue(
            controller.contains("idleTimerHook?(isSyncing)"),
            "hook must be driven by isSyncing")
        XCTAssertFalse(
            controller.contains("import UIKit"),
            "the shared PhotoKit adapter must remain UIKit-free; the host app owns the idle timer")
        let idleCalls = controller.components(separatedBy: "updateIdleTimerIfNeeded()").count - 1
        XCTAssertGreaterThanOrEqual(
            idleCalls, 2,
            "idle timer must be refreshed at start AND finish of a pass")
    }
}
