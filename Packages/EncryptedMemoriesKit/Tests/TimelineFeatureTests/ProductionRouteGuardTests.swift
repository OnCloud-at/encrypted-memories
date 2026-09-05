import Foundation
import Testing

/// Static source guards: removed/insecure production routes must not reappear, and the grid feed must use the
/// shared account-configured cache. Scans App/ + the package Sources/ (not Tests/, which holds these literals).
@Suite("Production route guards")
struct ProductionRouteGuardTests {
    /// `<repo>/Packages/EncryptedMemoriesKit/Tests/TimelineFeatureTests/ProductionRouteGuardTests.swift` to `<repo>`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TimelineFeatureTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // EncryptedMemoriesKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // <repo>
    }

    private func swiftFiles(under dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func sourceBlock(from startMarker: String, to endMarker: String, in source: String) -> String {
        guard let start = source.range(of: startMarker)?.lowerBound else { return "" }
        let tail = source[start...]
        guard let end = tail.range(of: endMarker)?.lowerBound else { return "" }
        return String(tail[..<end])
    }

    @Test func noRemovedProductionRoutesRemain() {
        // Removed tuning and transition flags must stay out of production; the current effect path is the default.
        let forbidden = [
            "anim-tuning", "TuningView", "AnimationTuning",
            "MetalGrid.focusRowTransition", "MetalGridFocusRowTransitionFlag",
            "MetalGrid.singleLatticeTransition", "MetalGridSingleLatticeTransitionFlag",
        ]
        let roots = [
            Self.repoRoot.appendingPathComponent("App"),
            Self.repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Sources"),
        ]
        var scanned = 0
        for root in roots {
            for file in swiftFiles(under: root) {
                scanned += 1
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                for token in forbidden {
                    #expect(!text.contains(token), "Forbidden production route '\(token)' found in \(file.path)")
                }
            }
        }
        #expect(scanned > 0, "Guard scanned no files - repoRoot path is wrong: \(Self.repoRoot.path)")
    }

    @Test func gridFeedUsesSharedConfiguredCache() throws {
        let mainView = Self.repoRoot.appendingPathComponent("App/Views/MainView.swift")
        let text = try String(contentsOf: mainView, encoding: .utf8)
        // The grid feed must be built with the account-configured shared cache, never a throwaway instance.
        #expect(text.contains("let feed = ThumbnailFeed("))
        #expect(text.contains("cache: OfflineLibraryManager.shared.cache"))
        #expect(!text.contains("cache: ThumbnailCache()"))
    }

    @Test func appAccountDataCacheIsEncryptedAndCleared() throws {
        let accountCache = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/AccountDataCache.swift"), encoding: .utf8)
        #expect(accountCache.contains("AES.GCM.seal"), "account cache must seal raw account JSON before writing")
        #expect(accountCache.contains("AES.GCM.open"), "account cache must authenticate/decrypt before use")
        #expect(accountCache.contains("HKDF<SHA256>.deriveKey"), "account cache key must be derived, not raw-used")
        #expect(accountCache.contains("keyPassword"), "account cache must be bound to the unlocked Proton secret")
        #expect(accountCache.contains("uid"), "account cache must be account-scoped")

        let driveSession = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSession.swift"), encoding: .utf8)
        #expect(
            driveSession.containsCodeFragmentIgnoringWhitespace(
                "AccountDataCache.save(users: uData, addresses: aData, uid: current.uid, keyPassword: current.keyPassword, in: accountCacheDirectory)"
            ))
        #expect(
            driveSession.containsCodeFragmentIgnoringWhitespace(
                "AccountDataCache.load(uid: current.uid, keyPassword: current.keyPassword, in: accountCacheDirectory)"))

        let bridge = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift"), encoding: .utf8)
        #expect(
            bridge.contains("driveSession.cachedAccountData()"),
            "offline cold start must use only the encrypted account cache fallback")

        let appModel = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/AppModel.swift"), encoding: .utf8)
        #expect(
            appModel.contains("await ProtonAuthLocalDataPurge.performOffMain("),
            "sign-out must await the complete shared file and Keychain purge")
    }

    @Test func bothAppleAppsCloseAccountStoresBeforePurgingOrRelogin() throws {
        let facade = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/ProtonClientFacade.swift"
            ), encoding: .utf8)
        #expect(facade.contains("public func shutdown() async"))
        #expect(facade.contains("await manager.shutdown()"))
        #expect(facade.contains("identityComposition.close()"))
        #expect(facade.contains("await bridge.shutdown()"))
        #expect(
            facade.range(of: "await manager.shutdown()")!.lowerBound
                < facade.range(of: "await bridge.shutdown()")!.lowerBound)
        #expect(
            facade.range(of: "await bridge.shutdown()")!.lowerBound
                < facade.range(of: "identityComposition.close()")!.lowerBound,
            "resolver SQLite must close only after shared backend admission has drained")

        let bridge = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift"
            ), encoding: .utf8)
        #expect(
            bridge.contains("shutdownGate.closeAdmission()"),
            "bridge shutdown must reject stale facade operations before its first await")
        let gateDrain = try #require(bridge.range(of: "await shutdownGate.run"))
        let cacheDrain = try #require(
            bridge.range(of: "await sharedAlbumSnapshotCache.invalidateAll()"))
        let sdkShutdown = try #require(bridge.range(of: "await photosClient.shutdown()"))
        #expect(
            gateDrain.lowerBound < cacheDrain.lowerBound,
            "cache-owned SDK tasks must drain only after admitted operations have joined")
        #expect(
            cacheDrain.lowerBound < sdkShutdown.lowerBound,
            "cache-owned SDK tasks must join before the native client shuts down")
        #expect(bridge.contains("private nonisolated func withOpenSession"))
        #expect(
            bridge.contains("admission: shutdownGate"),
            "album, sync, upload identity, and backend surfaces must share one admission owner")
        #expect(
            bridge.contains("await photosClient.shutdown()"),
            "facade shutdown must await the native Photos client before deleting its cache")

        let catalog = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/Albums/SDKAlbumCatalogBackend.swift"
            ), encoding: .utf8)
        #expect(
            catalog.contains("admission.withAdmission(operation)"),
            "published album catalog work must participate in bridge shutdown")

        let albumWriter = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/Albums/ProtonAlbumWriteService.swift"
            ), encoding: .utf8)
        #expect(
            albumWriter.contains("admission.withAdmission"),
            "album and album-sync writes must join bridge shutdown")

        let identity = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/Upload/ShutdownGatedUploadIdentityResolver.swift"
            ), encoding: .utf8)
        #expect(
            identity.contains("admission.withAdmission"),
            "old resolver references must not outlive their account store")

        let videoLoader = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/Streaming/ProtonVideoResourceLoader.swift"
            ), encoding: .utf8)
        #expect(videoLoader.contains("private let admission: JoinedShutdownGate"))
        #expect(
            videoLoader.components(separatedBy: "admission.withAdmission").count == 3,
            "issued AV assets must gate both range requests and forward-prefetch tasks")
        #expect(
            bridge.contains("admission: shutdownGate"),
            "the AV resource loader must share the bridge shutdown admission owner")

        let photosClient = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Vendor/sdk-swift/Sources/Client/EncryptedMemoriesClient/EncryptedMemoriesClient.swift"
            ), encoding: .utf8)
        #expect(photosClient.contains("public func shutdown() async"))
        #expect(
            photosClient.contains("await Self.freeEncryptedMemoriesClient(handle, logger)"),
            "native client teardown must be awaited instead of delegated to deinit")

        let photoBackup = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoLibraryBackupAdapter/PhotoLibraryBackupController.swift"
            ), encoding: .utf8)
        #expect(
            photoBackup.contains("isShuttingDown = true"),
            "queued PhotoKit callbacks must not restart work during logout")
        for store in ["queueStore?.close()", "stateStore?.close()", "catalogStore?.close()", "lockStore?.close()"] {
            #expect(photoBackup.contains(store), "Photo Library logout must close \(store)")
        }

        let albumSync = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoLibraryBackupAdapter/AlbumSyncController.swift"
            ), encoding: .utf8)
        #expect(
            albumSync.contains("isShuttingDown = true"),
            "queued album callbacks must not restart work during logout")
        #expect(albumSync.contains("mappingStore?.close()"))
        #expect(albumSync.contains("await remoteLinkLookup?.shutdown()"))

        let mac = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/AppModel.swift"), encoding: .utf8)
        #expect(
            mac.contains("AccountTeardownCoordinator(owners:"),
            "macOS logout must use the shared typed teardown ordering")
        #expect(mac.contains("await activeFacade?.shutdown()"))
        #expect(mac.contains("await ProtonAuthLocalDataPurge.performOffMain("))
        #expect(
            mac.contains("auth = .signingOut"),
            "logout must not reuse the generic library-loading state")
        #expect(mac.contains("await folderBackup?.shutdown()"))
        #expect(mac.contains("await photoBackup?.shutdown()"))
        #expect(mac.contains("await albumSync?.shutdown()"))
        #expect(mac.contains("await DebugLog.flush()"))
        #expect(mac.contains("case signOutFailed"))
        #expect(mac.contains("func retrySignOutCleanup()"))
        #expect(
            mac.range(of: "await activeFacade?.shutdown()")!.lowerBound
                < mac.range(of: "ProtonAuthLocalDataPurge.performOffMain(", options: .backwards)!.lowerBound)

        let mobile = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileLibraryModel.swift"), encoding: .utf8)
        #expect(
            mobile.contains("AccountTeardownCoordinator(owners:"),
            "iOS logout must use the shared typed teardown ordering")
        #expect(
            mobile.contains("private(set) var isSigningOut"),
            "iOS logout cleanup must keep a visible blocking state until purge completes")
        #expect(
            mobile.contains("isSigningOut = purgeClaim != nil"),
            "generic session teardown must not be presented as logout cleanup")
        #expect(mobile.contains("guard purgeClaim != nil else { return }"))
        #expect(mobile.contains("if report.succeeded"))
        #expect(
            mobile.contains("self.signOutCleanupFailed = true"),
            "iOS must replace the spinner with a retry state when the purge fails")
        #expect(mobile.contains("func retrySignOutCleanup()"))
        #expect(mobile.contains("await activeFacade?.shutdown()"))
        #expect(mobile.contains("if let purgeClaim"), "generic session teardown must never imply logout")
        #expect(mobile.contains("await ProtonAuthLocalDataPurge.performOffMain("))
        #expect(mobile.contains("await activePhotoBackup?.shutdown()"))
        #expect(mobile.contains("await activeAlbumSync?.shutdown()"))
        #expect(mobile.contains("await teardownTask.value"), "re-login must wait for the previous account teardown")
        #expect(mobile.contains("await DebugLog.flush()"))
        #expect(
            mobile.range(of: "await activeFacade?.shutdown()")!.lowerBound
                < mobile.range(of: "ProtonAuthLocalDataPurge.performOffMain(")!.lowerBound)

        let teardownCoordinator = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotosCore/AccountTeardownCoordinator.swift"
            ), encoding: .utf8)
        #expect(teardownCoordinator.contains("public actor AccountTeardownCoordinator"))
        #expect(teardownCoordinator.contains("case duplicateOwnerID(String)"))
        #expect(teardownCoordinator.contains("a failed owner never prevents later owners"))

        let macApp = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/EncryptedMemoriesApp.swift"), encoding: .utf8)
        #expect(macApp.contains(".launchVeil(purpose: model.launchVeilPurpose, model: model)"))
        #expect(
            macApp.contains("case .signingOut:\n            .signingOut"),
            "macOS sign-out must use the shared loading cover instead of a fallback spinner")
        #expect(macApp.contains("L10n.string(\"auth.signing_out\")"))

        let macSettings = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Views/SettingsView.swift"), encoding: .utf8)
        #expect(
            macSettings.contains(".signOutConfirmation(isPresented: $confirmSignOut, onConfirm: signOut)"),
            "macOS Settings must confirm before starting destructive account teardown")
        #expect(
            macApp.contains(".signOutConfirmation(isPresented: $confirmSignOut, onConfirm: signOut)"),
            "the macOS backend-error sign-out path must use the same confirmation")

        let mobileSettings = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileSettingsScreen.swift"), encoding: .utf8)
        #expect(
            mobileSettings.contains(".signOutConfirmation(isPresented: $confirmSignOut)"),
            "iOS and iPadOS must use the shared native sign-out confirmation")

        let sharedConfirmation = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/DesignSystemCore/SignOutConfirmation.swift"
            ), encoding: .utf8)
        #expect(sharedConfirmation.contains("alert("), "sign-out confirmation must use the native SwiftUI alert")
        #expect(sharedConfirmation.contains("role: .destructive"))
        #expect(
            sharedConfirmation.contains("sign_out.confirmation_message"),
            "the confirmation must explicitly explain local-data deletion")

        let mobileApp = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/EncryptedMemoriesMobileApp.swift"), encoding: .utf8
        )
        #expect(mobileApp.contains("MobileSignOutCleanupPresentation.resolve("))
        #expect(mobileApp.contains("MobileSignOutFailureView(onRetry: libraryModel.retrySignOutCleanup)"))
        #expect(mobileApp.contains("activityMessage: L10n.string(\"auth.signing_out\")"))

        let mobileSession = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileSessionModel.swift"), encoding: .utf8)
        #expect(mobileSession.contains("@Published private(set) var isSigningOut"))
        #expect(mobileSession.contains("isSigningOut = true"))
        #expect(mobileSession.contains("func completeSignOutPresentation()"))
    }

    @Test func mobileShareDeletesPlaintextTemporaryExportsAtEveryExit() throws {
        let support = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "iOSApp/MobileSelectionSupport.swift"
            ), encoding: .utf8)
        #expect(
            support.contains("completionWithItemsHandler"),
            "the share sheet must delete plaintext exports as soon as the activity completes")
        #expect(
            support.contains("static func dismantleUIViewController"),
            "interactive dismissal must retain a cleanup fallback")
        #expect(
            support.contains("presenter.present(controller, animated: true)"),
            "UIKit must own the activity controller presentation and dismissal lifecycle")
        #expect(
            support.contains("popover.sourceView = presenter.view"),
            "the direct UIKit presentation must remain valid on iPad")
        #expect(
            !support.contains("struct MobileActivityView"),
            "the activity controller must not return as SwiftUI sheet content")
        #expect(
            support.contains("MobileMediaExporter.cleanup(info.urls)"),
            "cancelling a partial share must delete the already-downloaded originals")
        #expect(
            support.contains("if exported.isEmpty { cleanup([]) }"),
            "a failed export run must remove its empty staging directory immediately")

        for path in [
            "iOSApp/MobileTimelineScreen.swift",
            "iOSApp/MobileAlbumsScreen.swift",
            "iOSApp/MobilePhotoViewer.swift",
            "iOSApp/MobileMapClusterSeriesScreen.swift",
        ] {
            let route = try String(
                contentsOf: Self.repoRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            #expect(route.contains(".mobileSharePresentation(selection: selection)"))
            #expect(!route.contains(".sheet(item: Binding(get: { selection.sharePayload"))
        }

        let settings = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileSettingsScreen.swift"),
            encoding: .utf8
        )
        #expect(settings.contains(".sheet(isPresented: $showsBugReport) { MobileBugReportSheet() }"))
        #expect(settings.contains("MobileMediaExporter.exportSupportReport(data)"))
        #expect(settings.contains("github.com/OnCloud-at/encrypted-memories/issues"))
        #expect(settings.contains("MobileSharePayload(urls: [url])"))
        #expect(settings.contains("openURL(Self.issueURL) { accepted in"))
        #expect(settings.contains("if !accepted"))
        #expect(!settings.contains("completionURL: Self.issueURL"))
        #expect(!settings.contains("BugReportSubmissionService"))
        #expect(!settings.contains("MobileActivityView"))
        #expect(!settings.contains("MobileSupportExport"))

        let macSettings = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Views/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(macSettings.contains("github.com/OnCloud-at/encrypted-memories/issues"))
        #expect(macSettings.contains("Task { await exportSupportReport() }"))
        #expect(macSettings.contains("if !NSWorkspace.shared.open(Self.issueURL)"))
        #expect(macSettings.contains("for: .itemReplacementDirectory"))
        #expect(macSettings.contains("try data.write(to: stagedFile, options: .atomic)"))
        #expect(macSettings.contains("replaceItemAt(destination, withItemAt: stagedFile)"))

        let timeline = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileTimelineScreen.swift"),
            encoding: .utf8
        )
        #expect(timeline.contains("private var selectionOptionsMenu: some View"))
        #expect(
            timeline.contains("Image(systemName: \"ellipsis\")"),
            "bulk favorite must live in the selection More menu beside Select/Done")
        #expect(
            !timeline.contains("Image(systemName: selectedAllFavorited ? \"heart.fill\" : \"heart\")"),
            "bulk favorite must not add a fourth action to the bottom selection bar")
        #expect(
            timeline.contains("await model.toggleFavorite(uids)"),
            "bulk favorite must use the shared optimistic mutation path")
        #expect(
            timeline.contains("!selection.selected.isEmpty && selection.selected.allSatisfy"),
            "the heart must remove favorites only when every selected item is already favorite")
    }

    @Test func canonicalRebuildRejectsInvalidSignedEntitlementsBeforeAndAfterInstall() throws {
        let rebuild = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("scripts/rebuild.sh"), encoding: .utf8)
        #expect(rebuild.contains("verify_mac_app \"$MAC_APP\""))
        #expect(rebuild.contains("verify_mac_app \"$MAC_DST\""))
        #expect(rebuild.contains("invalid entitlements blob"))
        #expect(rebuild.contains("codesign --verify --deep --strict \"$app\""))
    }

    @Test func mobileSessionDoesNotTurnEarlyKeychainUnavailabilityIntoSignOut() throws {
        let session = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "iOSApp/MobileSessionModel.swift"
            ), encoding: .utf8)
        #expect(
            session.contains("UIApplication.protectedDataDidBecomeAvailableNotification"),
            "iOS auth must retry after protected Keychain data becomes available")
        #expect(
            session.contains("bootstrapSessionIfNeeded()"),
            "iOS auth must re-read the existing session instead of requiring a new login")
        #expect(
            session.contains("apply(.checking)"),
            "unavailable protected data must remain a checking state")

        let login = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "iOSApp/MobileLoginView.swift"
            ), encoding: .utf8)
        #expect(
            login.contains("sessionModel.isCheckingSession"),
            "the login action must stay disabled while the existing session is being recovered")
    }

    @Test func nativeSDKCacheRemainsInMemoryForSafeSameProcessSignOut() throws {
        let bridge = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift"), encoding: .utf8)
        let config = try Self.body(
            of: bridge, from: "let config = ProtonDriveClientConfiguration(",
            to: "self.photosClient = try await EncryptedMemoriesClient(")
        #expect(
            !config.contains("cachePath:"),
            "SDK 0.25.0 does not dispose its SQLite repository, so sign-out must not persist that cache")
        #expect(
            !config.contains("cacheEncryptionKey:"),
            "an absent cache path selects the SDK's supported in-memory cache")
    }

    @Test func photosTrashUsesPhotosV2EndpointNotGenericDriveTrash() throws {
        let bridge = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift"), encoding: .utf8)
        let trashBody = try Self.body(
            of: bridge, from: "func trash(_ uids: [PhotoUID]) async throws {",
            to: "    func restore(_ uids: [PhotoUID]) async throws {")
        #expect(
            trashBody.contains("driveSession.trash(volumeID: root.volumeID"),
            "Photos trash must use the Photos-compatible v2 trash seam so Recently Deleted can list the item")
        #expect(
            !trashBody.contains("driveClient.trash"),
            "Generic Drive SDK trash does not populate the Photos trash route used by the library UI")

        let session = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSession.swift"), encoding: .utf8)
        #expect(session.contains("/drive/v2/volumes/\\(volumeID)/trash_multiple"))

        let capabilities = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/SDK/SDKCapabilities.swift"), encoding: .utf8)
        #expect(capabilities.contains("var trashViaSDK = false"))
    }

    @Test func exactPhotoDedupeUsesSDKWithoutRemovingDetailedSafetySeam() throws {
        let service = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/Upload/ProtonUploadDedupeService.swift"
            ), encoding: .utf8)
        #expect(service.contains("photosClient.findPhotoDuplicates("))
        #expect(service.contains("cancellationToken: cancellationToken"))
        #expect(
            service.contains("photosClient.cancelFindPhotoDuplicates(cancellationToken: cancellationToken)"),
            "task cancellation must cancel the matching native duplicate query")
        #expect(
            service.contains("session.findPhotoDuplicates(volumeID: context.volumeID, nameHashes: nameHashes)"),
            "draft, trash, and renamed-content semantics still require the detailed Photos response")

        let capabilities = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/SDK/SDKCapabilities.swift"
            ), encoding: .utf8)
        #expect(capabilities.contains("var exactPhotoDuplicatesViaSDK = true"))
    }

    @Test func libraryInvalidationUsesBoundedSDKEventsWithoutWeakeningDedupeEvidence() throws {
        let bridge = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift"
            ), encoding: .utf8)
        let probe = try Self.body(
            of: bridge,
            from: "private func volumeEventProbe(",
            to: "    private func eventCursor(")
        #expect(probe.contains("photosClient.enumerateEvents("))
        #expect(probe.contains("treeEventScopeId: volumeID"))
        #expect(probe.contains("cursor: cursor"))
        #expect(probe.contains("SDKCancellableOperation.run"))
        #expect(probe.contains("photosClient.cancelEnumerateEvents(cancellationToken: cancellationToken)"))
        #expect(!bridge.contains("driveSession.latestVolumeEventID"))
        #expect(bridge.contains("historyEventProbe.requiresAuthoritativeRefresh"))
        #expect(bridge.contains("cursor: nil"))
        #expect(bridge.contains("continuityRecovery.fetchInventory("))
        #expect(bridge.contains("continuityRecovery.qualify("))
        #expect(bridge.contains("continuityRecovery.persist("))
        #expect(bridge.contains("throw TimelineContinuityRecoveryPendingError()"))
        #expect(bridge.contains("DriveEventScopeAccessLostError"))

        let continuityPolicy = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/TimelineLoadCommitPolicy.swift"
            ), encoding: .utf8)
        #expect(continuityPolicy.contains("let probe = try await postInventoryProbe()"))
        #expect(continuityPolicy.contains("let cacheSaved = save()"))
        #expect(continuityPolicy.contains("TimelineContinuityPersistencePolicy.permitsMonitorAdvance"))

        let dedupe = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/Upload/ProtonUploadDedupeService.swift"
            ), encoding: .utf8)
        #expect(dedupe.contains("session.latestVolumeEventID(volumeID: material.context.volumeID)"))
        #expect(dedupe.contains("session.fetchVolumeEvents("))
        #expect(dedupe.contains("event.contextShareID"))
        #expect(dedupe.contains("event.linkType"))
        #expect(dedupe.contains("event.linkState"))
    }

    @Test func terminalDriveScopeLossPurgesStaleDataBeforeAuthenticatedRebuild() throws {
        let monitor = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/TimelineCore/LibraryChangeMonitor.swift"
            ), encoding: .utf8)
        let terminalBody = try Self.body(
            of: monitor,
            from: "private func handleTerminal(",
            to: "    private func retireCurrentTask()")
        #expect(terminalBody.contains("task = nil"))
        #expect(terminalBody.contains("lastToken = nil"))
        #expect(terminalBody.contains("await onTerminal(error)"))
        #expect(monitor.contains("case .terminal:"))
        #expect(monitor.contains("LibraryChangeRefreshTerminalError()"))

        let macModel = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/AppModel.swift"),
            encoding: .utf8)
        let macRecovery = try Self.body(
            of: macModel,
            from: "func recoverBackendAfterScopeAccessLoss() async {",
            to: "    /// Stop Smart Search")
        #expect(macRecovery.contains("AccountTeardownCoordinator"))
        #expect(macRecovery.contains("purgeCachesForAccountTeardown"))
        #expect(macRecovery.contains("ProtonDriveBackendFactory.purgeLocalAccountData"))
        #expect(macRecovery.contains("self.prepareBackend(session)"))
        #expect(!macRecovery.contains("authController.signOut"))
        #expect(!macRecovery.contains("ProtonAuthLocalDataPurge"))

        let mainView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Views/MainView.swift"),
            encoding: .utf8)
        #expect(mainView.contains("await model.recoverBackendAfterScopeAccessLoss()"))
        #expect(mainView.contains("timelineModel.initialLoadFailureReason == .scopeAccessLost"))
        #expect(mainView.contains("result.failureReason == .scopeAccessLost { return .terminal }"))

        let mobile = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileLibraryModel.swift"),
            encoding: .utf8)
        let mobileRecovery = try Self.body(
            of: mobile,
            from: "private func scheduleScopeRecovery(",
            to: "    /// Lifecycle-only platform seam")
        #expect(mobileRecovery.contains("self.snapshot = TimelineSnapshot()"))
        #expect(mobileRecovery.contains("await self?.retireForRetry(advanceLoadToken: false)"))
        #expect(mobileRecovery.contains("ProtonDriveBackendFactory.purgeLocalAccountData"))
        #expect(mobileRecovery.contains("preserveVisibleSnapshot: false"))
        #expect(mobileRecovery.contains("failedSession: ProtonSession"))
        #expect(mobileRecovery.contains("failedLoadGeneration: Int"))
        #expect(mobileRecovery.contains("scopeRecoveryCoordinator.schedule("))
        #expect(mobileRecovery.contains("self.loadToken &+= 1"))
        #expect(mobile.contains("self.scheduleScopeRecovery("))
        #expect(mobile.contains("await self?.recoverAfterScopeAccessLoss("))
        #expect(mobile.contains("catch let error as any LibraryChangeTerminalError"))
        #expect(mobile.contains("catch is any LibraryChangeTerminalError"))
        #expect(mobile.contains("try requireCurrentMutation(refreshLease)"))
        #expect(mobileRecovery.components(separatedBy: "scopePresentationRevision &+= 1").count - 1 == 1)
        let scopeRevision = try #require(mobileRecovery.range(of: "scopePresentationRevision &+= 1"))
        let snapshotClear = try #require(mobileRecovery.range(of: "self.snapshot = TimelineSnapshot()"))
        #expect(scopeRevision.lowerBound < snapshotClear.lowerBound)

        let recoveryDriver = try Self.body(
            of: mobile,
            from: "func run() async {",
            to: "}\n\n/// Owns signed-in iOS/iPadOS library state")
        let ownerRetirement = try #require(recoveryDriver.range(of: "await retireOwners()"))
        let accountPurge = try #require(recoveryDriver.range(of: "await purgeLostScope()"))
        let rebuild = try #require(recoveryDriver.range(of: "rebuild()"))
        #expect(ownerRetirement.lowerBound < accountPurge.lowerBound)
        #expect(accountPurge.lowerBound < rebuild.lowerBound)
        #expect(recoveryDriver.components(separatedBy: "guard !Task.isCancelled, isCurrent()").count - 1 == 4)
        let mobileRetry = try Self.body(
            of: mobile,
            from: "func retry() async {",
            to: "    /// Schedules a Drive-scope recovery")
        #expect(!mobileRetry.contains("scopePresentationRevision"))

        let mobileRoot = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/EncryptedMemoriesMobileApp.swift"),
            encoding: .utf8)
        #expect(mobileRoot.contains(".id(libraryModel.scopePresentationRevision)"))
    }

    @Test func iOSLongPressRoutesIntoTheExistingSelectionState() throws {
        let host = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/TimelineUIKitFeature/UIKitTimelineGridHost.swift"
            ), encoding: .utf8)
        #expect(host.contains("public var onBeginSelection: ((PhotoItem) -> Void)?"))
        #expect(host.contains("beginSelection(with: item)"))
        #expect(
            host.contains("dragSelect.minimumPressDuration = 0.35"),
            "long-press selection must leave enough time for a normal scroll gesture to win")
        #expect(
            host.contains("tap.require(toFail: dragSelect)"),
            "releasing the entry long press must not also toggle its selected anchor as a tap")
        let beginBody = try Self.body(
            of: host,
            from: "private func beginSelection(with item: PhotoItem) {",
            to: "    private func beginDragSelect("
        )
        #expect(beginBody.contains("selectionMode = true"))
        #expect(
            beginBody.contains("selectedUIDs.insert(item.uid)"),
            "the long-pressed photo must be visibly selected in the same gesture that enters selection mode")
        #expect(
            beginBody.contains("onBeginSelection?(item)"),
            "the shell selection controller remains the authoritative state owner")
        #expect(
            host.contains("if selectionMode { return true }"),
            "active selection must retain the existing long-press range drag")

        let timeline = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "iOSApp/MobileTimelineScreen.swift"
            ), encoding: .utf8)
        #expect(
            timeline.contains("onBeginSelection: selection.begin"),
            "the main iOS grid must enter the same shared selection state used by the Select button")
    }

    @Test func mobileGridBinaryConfirmationsUseSharedNativeAlerts() throws {
        let support = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "iOSApp/MobileSelectionSupport.swift"
            ), encoding: .utf8)
        #expect(support.contains("private struct MobileSelectionAlertsModifier: ViewModifier"))
        #expect(
            support.contains(".alert(\n                String(localized: \"selection.share_partial_title\")"),
            "partial-share proceed/cancel is a binary alert, not an anchored action menu")
        #expect(support.contains("trashTitle: String = String(localized: \"selection.trash_title\")"))
        #expect(
            support.contains(".alert(\n                trashTitle"),
            "destructive trash confirmation is a binary alert, not an anchored action menu")

        for path in [
            "iOSApp/MobileTimelineScreen.swift",
            "iOSApp/MobileAlbumsScreen.swift",
            "iOSApp/MobileMapClusterSeriesScreen.swift",
            "iOSApp/MobilePhotoViewer.swift",
        ] {
            let screen = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(
                screen.contains(".mobileSelectionAlerts(selection: selection")
                    || screen.contains(".mobileSelectionAlerts(\n            selection: selection"),
                "\(path) must use the one shared mobile selection-alert presentation")
            #expect(
                !screen.contains("String(localized: \"selection.share_partial_title\")"),
                "\(path) must not duplicate the partial-share confirmation")
            #expect(
                !screen.contains("String(localized: \"selection.trash_title\")"),
                "\(path) must not duplicate the destructive confirmation")
        }
    }

    @Test func backupStatusDwellAndTransitionsStaySharedAcrossPlatforms() throws {
        let shared = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/UploadFeature/BackupStatusRowModel.swift"
            ), encoding: .utf8)
        #expect(shared.contains("public final class BackupStatusRowModel"))
        #expect(shared.contains("BackupStatusStabilizer()"))
        #expect(shared.contains("wakeTask"))
        #expect(
            !shared.contains("layoutRevision"),
            "status truth may wake on time, but optional text must never drive geometry animation")

        for path in ["App/Views/SettingsView.swift", "iOSApp/MobileSettingsScreen.swift"] {
            let settings = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(
                settings.contains("@State private var rowModel = BackupStatusRowModel()"),
                "\(path) must render the same stabilized backup presentation")
            #expect(
                !settings.contains("value: rowModel.layoutRevision)"),
                "\(path) must not animate the whole status hierarchy when optional text changes")
        }
        let mac = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "App/Views/SettingsView.swift"
            ), encoding: .utf8)
        #expect(mac.contains("subtitleSlot(display)"))
        #expect(
            mac.contains("transferSlot(display)"),
            "macOS must reserve transfer liveness instead of inserting/removing a row")
        #expect(
            mac.contains("progressSlot(display)"),
            "macOS must keep progress in one fixed location")
        let mobile = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "iOSApp/MobileSettingsScreen.swift"
            ), encoding: .utf8)
        #expect(mobile.contains("statusDetails(display)"))
        #expect(
            mobile.contains("value: display.detailLayout"),
            "mobile geometry may animate only on stable phase-level detail layout changes")
        #expect(
            !mobile.contains("final class BackupStatusRowModel"),
            "the mobile shell must not own a duplicate status scheduler")
        #expect(
            mobile.contains(".buttonStyle(.borderless)"),
            "independent backup actions in one iOS Form row must not share the automatic row tap")
    }

    @Test func mobileSettingsRefreshesCacheSizeWithoutPollingAccountMetadata() throws {
        let settings = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "iOSApp/MobileSettingsScreen.swift"
            ), encoding: .utf8)
        #expect(settings.contains("Task.sleep(for: .seconds(10))"))
        #expect(settings.contains("await refreshCacheSize()"))
        #expect(settings.contains("Task.sleep(for: .seconds(300))"))
        #expect(settings.contains("await libraryModel.refreshAccountInfo()"))
        #expect(
            !settings.contains("refreshSettingsValues"),
            "cache polling must not turn the account refresh into a ten-second network poll")
    }

    @Test func binaryConfirmationsDoNotUseAnchoredActionMenus() throws {
        for path in [
            "App/Views/SettingsView.swift",
            "iOSApp/MobileAlbumSyncScreen.swift",
            "Packages/EncryptedMemoriesKit/Sources/MLSearchFeature/SmartSearchSettingsSection.swift",
        ] {
            let source = try String(
                contentsOf: Self.repoRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            #expect(
                !source.contains(".confirmationDialog("),
                "\(path) contains only binary confirmations, which must use native alerts")
        }
    }

    @Test func albumRemovalOffersTheSameNativeChoiceOnApplePlatforms() throws {
        for path in [
            "App/Views/MainView.swift",
            "iOSApp/MobileAlbumsScreen.swift",
        ] {
            let source = try String(
                contentsOf: Self.repoRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            #expect(
                source.contains(".confirmationDialog("),
                "\(path) must present the album-membership and trash actions as one native choice")
            #expect(source.contains("albums.remove_photos_action"))
            #expect(source.contains("albums.move_photos_to_trash"))
        }
    }

    @Test func mobileViewerUsesItsLiveViewportForDecodeBudgets() throws {
        let viewer = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobilePhotoViewer.swift"),
            encoding: .utf8
        )
        #expect(
            viewer.contains(".onGeometryChange(for: CGSize.self)"),
            "the viewer must react to rotation and iPad split-view resizing")
        #expect(
            viewer.contains("viewportPoints: viewportSize"),
            "zoomed decoding must use the current viewer viewport")
        #expect(
            viewer.containsCodeFragmentIgnoringWhitespace(".task(id: ViewerImageLoadPolicy.LoadIdentity"),
            "the base image task must use the shared bounded load identity")
        #expect(
            viewer.contains("maxPixelSize: displayLoadCap"),
            "a transition-sized first decode must upgrade when the bounded viewport cap grows")
        #expect(
            viewer.contains("ViewerImageLoadPolicy.shouldReplaceDisplayedImage"),
            "a smaller decoded preview must never replace the visible thumbnail")
        #expect(
            !viewer.contains("viewportWidth"),
            "raw viewport dimensions must stay out of the base task identity")
        #expect(
            !viewer.contains("UIScreen.main"),
            "global screen bounds are incorrect for resizable iPad and future form factors")
        #expect(
            viewer.components(separatedBy: "imageStore.originalImage(for:").count - 1 == 2,
            "only zoom and Live Photo composite readiness may request original image bytes")
        let liveStillStart = try #require(viewer.range(of: "private func loadFullResolutionLivePhotoStill"))
        let liveStillEnd = try #require(
            viewer.range(
                of: "    private func loadZoomedDecodeIfNeeded",
                range: liveStillStart.upperBound..<viewer.endIndex
            ))
        let liveStill = String(viewer[liveStillStart.lowerBound..<liveStillEnd.lowerBound])
        #expect(
            liveStill.contains("guard LivePhotoMotionPolicy.shouldPrepare"),
            "fit-to-screen original loading must stay limited to the current Live Photo")
        #expect(
            liveStill.contains("imageStore.originalImage(for:"),
            "Live Photo readiness requires original bytes, not only the preview")
    }

    @Test func appleViewersUseSharedLivePhotoCompositeReadiness() throws {
        let macModel = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/PhotoViewerModel.swift"
            ),
            encoding: .utf8
        )
        let macView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/PhotoViewerView.swift"
            ),
            encoding: .utf8
        )
        let mobileView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobilePhotoViewer.swift"),
            encoding: .utf8
        )

        #expect(macModel.contains("LivePhotoCompositeReadiness.resolve("))
        #expect(macView.contains("model.livePhotoReadiness == .loading"))
        #expect(mobileView.contains("private var livePhotoReadiness: LivePhotoCompositeReadiness"))
        #expect(mobileView.contains("case .loading:\n                    ProgressView()"))
    }

    @Test func mobileVideoKeepsPosterUntilAVKitCanDisplayTheFirstFrame() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobilePhotoViewer.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private struct MobileVideoPage"))
        let end = try #require(
            source.range(
                of: "private struct ViewerPinchState",
                range: start.upperBound..<source.endIndex
            ))
        let video = String(source[start.lowerBound..<end.lowerBound])

        #expect(video.contains("if let player {\n                MobileNativeVideoPlayer("))
        #expect(
            video.contains("poster: poster"),
            "the native AVKit surface must retain the existing thumbnail as its startup poster")
        #expect(
            video.containsCodeFragmentIgnoringWhitespace(
                ".onAppear {\n                        if isCurrent {\n                            playbackIntendsToPlay = true\n                            player.play()"
            ),
            "the current player must be started after AVKit mounts, not only before its view exists")
        #expect(
            video.contains("} else {\n                // AVKit is not mounted yet"),
            "the poster and app loader must exist only before the native player surface")
        #expect(
            source.contains("controller.contentOverlayView"),
            "the poster must sit below native AVKit controls instead of covering their hit-testing")
        #expect(
            source.contains("controller.observe(\n                \\.isReadyForDisplay"),
            "the poster may leave only when AVKit proves its first frame is displayable")
        #expect(
            !source.contains("VideoTimeObserverBox"),
            "display readiness must not regress to a periodic playback-time observer")
    }

    @Test func mobileVideoCancellationDoesNotBecomePlaybackFailure() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobilePhotoViewer.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private struct MobileVideoPage"))
        let end = try #require(
            source.range(
                of: "private struct ViewerPinchState",
                range: start.upperBound..<source.endIndex
            ))
        let video = String(source[start.lowerBound..<end.lowerBound])
        let prepare = try Self.body(of: video, from: "private func prepare() async", to: "private func teardown()")

        #expect(
            prepare.containsCodeFragmentIgnoringWhitespace(
                "guard isCurrent, player == nil, let backend = libraryModel.backend else { return } failed = false"
            ),
            "a new current preparation must clear a stale failure before streaming starts")
        #expect(
            prepare.containsCodeFragmentIgnoringWhitespace("} catch is CancellationError { return }"),
            "cancelled video preparation must not render the playback failure state")
        #expect(
            prepare.containsCodeFragmentIgnoringWhitespace(
                "guard !Task.isCancelled, isCurrent else { return } failed = true"
            ),
            "only a current, non-cancelled real error may render playback failure")
        #expect(
            prepare.range(of: "guard !Task.isCancelled else { return }")!.lowerBound
                < prepare.range(of: "let newPlayer = AVPlayer")!.lowerBound,
            "cancellation must be checked before attaching an AVPlayer")
    }

    @Test func mobileVideoKeepsViewerGesturesOnTheNativePlayerSurface() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobilePhotoViewer.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private struct MobileNativeVideoPlayer"))
        let end = try #require(
            source.range(
                of: "private struct MobileVideoPage",
                range: start.upperBound..<source.endIndex
            ))
        let player = String(source[start.lowerBound..<end.lowerBound])

        #expect(
            player.contains("AVPlayerViewController"),
            "video must expose a native UIKit surface instead of hiding gestures behind SwiftUI VideoPlayer")
        #expect(
            player.contains("let gestureSurface = controller.view!"),
            "viewer gestures must observe the whole native player surface, including playback content")
        #expect(
            player.contains("imageView.isUserInteractionEnabled = false"),
            "content-overlay decoration must stay noninteractive so gestures remain on the native root surface")
        #expect(player.contains("dismissPan.cancelsTouchesInView = false"))
        #expect(player.contains("dismissPinch.cancelsTouchesInView = false"))
        #expect(
            player.contains("shouldRecognizeSimultaneouslyWith"),
            "AVKit controls and viewer gestures must remain simultaneous")
        #expect(
            player.contains("ViewerDragDismissPolicy.prefersDismissalAxis"),
            "video dismissal must use the shared, slightly diagonal axis policy")
        #expect(
            player.contains("controller.videoBounds"),
            "custom video dismiss gestures must observe AVKit's public displayed media bounds")
        #expect(
            player.contains("presentationSize"),
            "video zoom detection must compare AVKit bounds with the current item's media aspect")
        #expect(
            player.contains("isNativeVideoZoomed"),
            "native video zoom must keep custom dismiss gestures from moving the page")
        #expect(
            !source.contains(".simultaneousGesture(dragToDismissGesture)"),
            "the runtime-disproved SwiftUI gesture layer must be removed, not stacked underneath")
    }

    @Test func mobileVideoDoesNotStackAppCornerControlsOverNativeAVKitChrome() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobilePhotoViewer.swift"),
            encoding: .utf8
        )
        let viewerHeader = try Self.body(
            of: source,
            from: "private var viewerHeader: some View",
            to: "private var viewerBackButton: some View"
        )
        let videoPlayer = try Self.body(
            of: source,
            from: "private struct MobileNativeVideoPlayer: UIViewControllerRepresentable",
            to: "private struct MobileVideoPlaybackControls: View"
        )
        let videoControls = try Self.body(
            of: source,
            from: "private struct MobileVideoPlaybackControls: View",
            to: "private struct MobileVideoPage: View"
        )

        #expect(viewerHeader.contains("viewerBackButton"))
        #expect(viewerHeader.contains("viewerTitlePill"))
        #expect(
            viewerHeader.contains("viewerActionButton"),
            "photos and videos must use the same compact top-row ownership")
        #expect(
            !viewerHeader.contains("currentItemUsesNativeVideoChrome"),
            "asynchronous media routing must not insert or remove top-row controls")
        #expect(
            videoPlayer.contains("controller.showsPlaybackControls = false"),
            "AVKit's AirPlay, volume, and duplicate close controls must stay hidden")
        #expect(
            source.contains("private struct MobileVideoPlaybackControls: View"),
            "hiding AVKit chrome must not remove play, seek, and scrub behavior")
        #expect(!source.contains("gobackward.10"))
        #expect(
            !source.contains("goforward.10"),
            "the accepted bottom transport keeps only play or pause plus direct scrubbing")
        #expect(
            source.containsCodeFragmentIgnoringWhitespace("Slider(value:"),
            "the app-owned video surface must retain deterministic seeking")
        #expect(
            source.contains("layoutProfile.bottomChromeHeight"),
            "video transport must reserve the responsive filmstrip and action rows without moving them")
        #expect(
            source.contains("playbackIntendsToPlay"),
            "a buffering player must retain the user's play intent so Pause can stop it")
        #expect(
            source.contains("playbackIsBuffering"),
            "the video controls must distinguish buffering from paused playback")
        #expect(videoControls.contains("let isLoading: Bool"))
        #expect(
            videoControls.contains("ProgressView()"),
            "the scrubber must show native indeterminate progress while playback waits")
        #expect(
            videoControls.contains(".frame(width: 24, height: layoutProfile.controlSide)"),
            "the trailing progress slot must remain fixed so buffering does not move the scrubber")
        #expect(videoControls.contains(".opacity(isLoading ? 1 : 0)"))
        #expect(videoControls.contains(".accessibilityLabel(Text(\"viewer.video_loading_a11y\"))"))
        #expect(
            source.contains("MobileVideoPlaybackIntent.showsLoadingIndicator"),
            "loading must follow retained play intent until AVPlayer reports active playback")
        #expect(
            source.contains("MobileVideoPlaybackIntent.reachedEnd(current: playbackTime, duration: playbackDuration)"),
            "reaching the end must reset play intent so the next tap restarts instead of pausing again")
        #expect(
            source.contains("player.seek(to: .zero"),
            "Play at the terminal frame must restart the video")
        #expect(!source.contains(".simultaneousGesture(videoDismissDragGesture)"))
        #expect(
            !source.contains(".simultaneousGesture(videoDismissPinchGesture)"),
            "a full-screen SwiftUI gesture layer above AVKit must not steal horizontal pager swipes")
        #expect(videoPlayer.contains("gestureSurface.addGestureRecognizer(dismissPan)"))
        #expect(
            videoPlayer.contains("gestureSurface.addGestureRecognizer(dismissPinch)"),
            "the existing native media-surface dismiss gestures must remain installed")
        #expect(
            source.contains(".accessibilityLabel(Text(\"viewer.video_position_a11y\"))"),
            "the replacement scrubber must expose a deterministic VoiceOver label")
        #expect(
            source.contains("controller.allowsPictureInPicturePlayback = true"),
            "removing top-row AVKit chrome must not disable background Picture in Picture capability")
    }

    @Test func mobileViewerKeepsMetadataRowStableAcrossPhotoVideoPaging() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobilePhotoViewer.swift"),
            encoding: .utf8
        )

        #expect(
            source.contains("MobileViewerChromeOverlay(showsChrome: chromeVisible)"),
            "photo and video pages must mount one shared chrome tree so metadata cannot jump between rows")
        #expect(
            source.contains("private var viewerHeader: some View"),
            "one shared first row must own close, POI/date, and actions for every media type")
        #expect(
            source.contains("MobileViewerHeaderLayout.titleWidth(containerWidth: proxy.size.width)"),
            "the centered title pill must consume only the space left on compact iPhones")
        let viewerChrome = try Self.body(
            of: source,
            from: "private var viewerTopChrome: some View",
            to: "private var viewerHeader: some View"
        )
        #expect(viewerChrome.contains(".frame(maxWidth: .infinity)"))
        #expect(
            !viewerChrome.contains("maxHeight: .infinity"),
            "the shared header must stay top-anchored without claiming the native media gesture surface")
        #expect(viewerChrome.contains("if currentDisplayedItem?.isLivePhoto == true"))
        #expect(
            viewerChrome.contains("viewerLiveIndicator"),
            "Live Photo status must use the fixed second header row instead of disappearing over bright media")
        let liveIndicator = try Self.body(
            of: source,
            from: "private var viewerLiveIndicator: some View",
            to: "private var viewerActionMenu: some View"
        )
        #expect(
            liveIndicator.contains(".allowsHitTesting(false)"),
            "the fixed Live Photo status row must not steal paging or dismiss gestures")
        #expect(
            !liveIndicator.contains(".accessibilityHidden(true)"),
            "the visible Live Photo status must remain discoverable to VoiceOver")
        let imagePage = try Self.body(
            of: source,
            from: "private struct MobileImagePage: View",
            to: "private struct MobileNativeVideoPlayer: UIViewControllerRepresentable"
        )
        #expect(
            !imagePage.contains("MobileLiveBadge()"),
            "the old image-anchored Live badge must be removed, not stacked under the new header badge")
    }

    @Test func mobileViewerChromeLeavesTheNativeMediaGestureSurfaceReachable() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobilePhotoViewer.swift"),
            encoding: .utf8
        )
        let support = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileViewerSupport.swift"),
            encoding: .utf8
        )
        let bottomChrome = try Self.body(
            of: source,
            from: "private var viewerBottomChrome: some View",
            to: "private var viewerHeader: some View"
        )

        #expect(
            !bottomChrome.contains(".allowsHitTesting(true)"),
            "a full-screen bottom chrome layer must not claim long presses outside its visible controls")
        #expect(support.contains(".overlay(alignment: .top)"))
        #expect(
            support.contains(".overlay(alignment: .bottom)"),
            "top and bottom controls must use separate bounded hit-test regions")
        #expect(
            source.containsCodeFragmentIgnoringWhitespace("UILongPressGestureRecognizer(target: context.coordinator"),
            "the native image surface must retain its Live Photo press recognizer")
        #expect(
            source.contains("motion.play(for: item, streamer: streamer)"),
            "Live Photo preparation must begin from the user press")
        #expect(
            !source.contains("motion.prepare(for: item, streamer: streamer)"),
            "ordinary page appearance must not preload Live Photo motion")
        #expect(
            source.contains("case .began:\n                motionActive = true\n                onMotionStart?()"),
            "the press threshold must still start the shared Live Photo motion controller")
    }

    @Test func macOSViewerRoutesNativeTrackpadPagingIntoContextNavigation() throws {
        let view = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/PhotoViewerView.swift"
            ),
            encoding: .utf8
        )
        let zoomSurface = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/ZoomableImageView.swift"
            ),
            encoding: .utf8
        )

        #expect(view.contains("model.previousInContext()"))
        #expect(view.contains("model.nextInContext()"))
        #expect(
            view.contains("onPageSwipe:"),
            "both native macOS media surfaces must route page swipes through the shared viewer model")
        #expect(
            view.contains("override func scrollWheel(with event: NSEvent)"),
            "the native AVKit video surface must accept two-finger trackpad paging")
        #expect(
            zoomSurface.contains("override func scrollWheel(with event: NSEvent)"),
            "the native AppKit image surface must accept two-finger trackpad paging")
        #expect(!view.contains("NSEvent.isSwipeTrackingFromScrollEventsEnabled"))
        #expect(
            !zoomSurface.contains("NSEvent.isSwipeTrackingFromScrollEventsEnabled"),
            "two-finger paging must not depend on the optional system swipe-navigation preference")
        #expect(
            zoomSurface.contains("magnification <= minMagnification"),
            "a zoomed photo must retain horizontal pan instead of changing pages")
    }

    @Test func mobileViewerBottomChromeUsesCoreUIDSelectionAndBoundedNativeFilmstrip() throws {
        let viewer = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobilePhotoViewer.swift"),
            encoding: .utf8
        )
        let filmstrip = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileViewerFilmstrip.swift"),
            encoding: .utf8
        )
        let support = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileViewerSupport.swift"),
            encoding: .utf8
        )

        #expect(viewer.contains("private let pageIndex: ViewerPageIndex"))
        #expect(viewer.contains("MobileViewerFilmstrip("))
        #expect(
            viewer.contains("selectedUID: currentBaseItem?.uid"),
            "the outer route strip must not confuse a nested burst selection with its library page")
        #expect(support.contains(".overlay(alignment: .bottom)"))
        #expect(
            !support.contains("maxHeight: .infinity, alignment: .bottom"),
            "bottom controls must overlay media without becoming a full-screen hit-test surface")
        #expect(
            !viewer.contains("safeAreaInset(edge: .bottom"),
            "viewer controls must overlay media instead of refitting it when chrome changes")
        #expect(
            filmstrip.contains("UICollectionView"),
            "large libraries need reusable visible cells rather than one SwiftUI view per asset")
        #expect(filmstrip.contains("prepareForReuse()"))
        #expect(
            filmstrip.contains("thumbnailTask?.cancel()"),
            "a reused thumbnail cell must not publish an old identity's late image")
        #expect(viewer.contains("favoriteTask: Task<Void, Never>?"))
        #expect(viewer.contains("restoreTask: Task<Void, Never>?"))
        #expect(
            viewer.contains("currentDisplayedItem?.uid == uid"),
            "late viewer mutations must not publish an error or dismissal for a different page")
        let restore = try Self.body(
            of: viewer,
            from: "private func restore(_ item: PhotoItem)",
            to: "private func toggleFavorite(_ uid: PhotoUID)"
        )
        #expect(
            !restore.contains("restoreTask?.cancel()"),
            "paging must not cancel a restore that can already have committed remotely")
        #expect(
            !viewer.contains("restoreTask?.cancel()"),
            "no viewer lifecycle path may cancel a restore that can already have committed remotely")
        let completion = try #require(restore.range(of: "viewerRouter.noteCompletedMutation(uid: uid)"))
        let presentationGate = try #require(restore.range(of: "guard requestGeneration == restoreRequestGeneration"))
        #expect(
            completion.lowerBound < presentationGate.lowerBound,
            "a committed restore must reconcile the source route before viewer presentation is gated")
    }

    @Test func trashMutationsDecodeMultistatusAndListingResolvesViaFetchMetadata() throws {
        let session = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSession.swift"), encoding: .utf8)
        // trash/restore answer HTTP 200 with per-item codes; ignoring the body silently drops failures.
        #expect(
            session.contains("BatchLinkResponses"),
            "trash_multiple/restore_multiple must decode the per-item multistatus body")
        #expect(
            session.contains("throw DriveBatchActionError"),
            "a failed item must surface as a thrown error, never as silent success")
        // The volume trash listing returns only {ShareID, LinkIDs} groups; link bodies come from
        // fetch_metadata. The listing must resolve those identifiers through the batch endpoint before
        // the Recently Deleted view can render its items.
        #expect(session.contains("VolumeTrashResponse"))
        #expect(
            session.contains("links/fetch_metadata"),
            "trash listing must resolve ids via the per-share fetch_metadata batch")

        // Platform shells must not swallow trash/restore failures - the grid would pretend the photo
        // was deleted while the server still has it outside the trash.
        let mainView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Views/MainView.swift"), encoding: .utf8)
        #expect(!mainView.contains("try? await backend.trash"), "macOS must surface trash failures")
        #expect(!mainView.contains("try? await backend.restore"), "macOS must surface restore failures")
    }

    @Test func emptyTrashUsesPhotosSdkAndIsSurfacedByBothShells() throws {
        let provider = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotosCore/PhotoLibrary.swift"), encoding: .utf8)
        #expect(provider.contains("func emptyTrash() async throws"))

        let bridge = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift"), encoding: .utf8)
        let body = try Self.body(
            of: bridge, from: "func emptyTrash() async throws {", to: "    /// Builds timeline sections")
        #expect(body.contains("SDKCancellableOperation.run"))
        #expect(body.contains("photosClient.emptyTrash(cancellationToken: cancellationToken)"))
        #expect(body.contains("photosClient.cancelEmptyTrash(cancellationToken: cancellationToken)"))
        #expect(!body.contains("driveClient.emptyTrash"))

        let photosClient = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Vendor/sdk-swift/Sources/Client/EncryptedMemoriesClient/EncryptedMemoriesClient.swift"),
            encoding: .utf8)
        #expect(photosClient.contains("Proton_Drive_Sdk_DrivePhotosClientEmptyTrashRequest"))

        let packaging = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Vendor/sdk-swift/Sources/Plumbing/Message+Packaging.swift"), encoding: .utf8)
        #expect(packaging.contains(".drivePhotosClientEmptyTrash(request)"))

        let mainView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Views/MainView.swift"), encoding: .utf8)
        #expect(mainView.contains("confirmEmptyTrash"))
        #expect(mainView.contains("backend.emptyTrash()"))

        let mobileCollections = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileAlbumsScreen.swift"), encoding: .utf8)
        #expect(mobileCollections.contains("model.emptyTrash()"))
        #expect(
            mobileCollections.contains("guard filter == .trash, !snapshot.isEmpty, !isEmptyingTrash"),
            "mobile Empty Trash must reject duplicate requests while the first mutation is in flight")
        #expect(mobileCollections.contains("defer { isEmptyingTrash = false }"))
    }

    @Test func mobileSelectionSerializesMutations() throws {
        let support = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileSelectionSupport.swift"),
            encoding: .utf8
        )
        #expect(support.contains("var isBusy: Bool { isExporting || isFavoriting || isTrashing }"))
        #expect(
            support.contains("guard !uids.isEmpty, !isBusy else { return }"),
            "a second trash request must not race the first")
        #expect(
            support.contains("defer { isTrashing = false }"),
            "the shared selection state must always leave its mutation state")
    }

    @Test func locationCrawlYieldsOnVisiblePressureAndSharesTheCorePath() throws {
        // Map crawling yields only to live visible-demand pressure, not whole-library thumbnail work.
        for shell in ["App/Offline/OfflineLibraryManager.swift", "iOSApp/MobileLibraryModel.swift"] {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(shell), encoding: .utf8)
            #expect(
                text.contains("LocationCrawl.metadataProbe"),
                "\(shell) must use the shared MediaLocationCore probe, not platform-local GPS parsing")
            #expect(
                text.contains("hasVisibleThumbnailPressure()"),
                "\(shell) must yield the GPS crawl on visible pressure only")
            #expect(
                !text.contains("?.hasPendingThumbnailWork()"),
                "\(shell) must never park the GPS crawl behind the full thumbnail crawl")
        }

        // Both map surfaces observe the scan progress so "scanning" and "no geotagged photos" are
        // distinguishable - never a blanket "no places yet" while the crawl still runs.
        for screen in ["App/Views/MainView.swift", "iOSApp/MobileMapScreen.swift"] {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(screen), encoding: .utf8)
            #expect(text.contains("scanProgress"), "\(screen) must observe the crawl's scan progress")
            #expect(text.contains("map.scanning_title"), "\(screen) must show a distinct scanning state")
            #expect(
                text.contains("map.no_places_found_message"),
                "\(screen) must reserve 'no geotagged photos' for a COMPLETED scan")
        }
    }

    @Test func mobileRetryAndLocationCrawlRetirementAreAwaitable() throws {
        let mobile = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileLibraryModel.swift"),
            encoding: .utf8
        )
        #expect(
            mobile.contains("func retry() async"),
            "the iOS retry action must expose an awaitable retirement boundary")
        #expect(
            mobile.contains("locationCrawlStartTask"),
            "the delayed iOS crawl starter must remain retained for teardown")
        #expect(
            mobile.contains("await activeLocationCrawlStarter?.value"),
            "iOS teardown must join the delayed crawl starter")
        #expect(
            mobile.contains("await activePrefetchStartTask?.value"),
            "iOS retry must join the delayed thumbnail-prefetch starter")
        #expect(
            mobile.contains("await activeFavoriteLoadTask?.value"),
            "iOS retry must join late favorite loads before facade shutdown")
        #expect(
            mobile.contains("await activeThumbnailUpdateTask?.value"),
            "iOS retry must join new-asset thumbnail resolution before facade shutdown")
        #expect(
            mobile.contains("await activePhotoBackup?.shutdown()"),
            "iOS retry must await the photo-backup owner")
        #expect(
            mobile.contains("await activeAlbumSync?.shutdown()"),
            "iOS retry must await the album-sync owner")
        #expect(
            mobile.contains("await activeFacade?.shutdown()"),
            "iOS retry must await the facade owner")
        #expect(
            mobile.contains("let activeThumbnailFeed = thumbnailFeed"),
            "retry and sign-out must retain the old feed until its workers are joined")
        #expect(
            mobile.contains("await activeThumbnailFeed?.stopPrefetch()"),
            "retry and sign-out must join old feed workers before closing the backend")
        #expect(
            mobile.contains("let activeRetry = retryTask"),
            "sign-out must snapshot an in-flight transient retry before clearing account owners")
        #expect(
            mobile.contains("activeRetry?.cancel()"),
            "sign-out must cancel an in-flight transient retry")
        #expect(
            mobile.contains("await activeRetry?.value"),
            "sign-out must join an in-flight transient retry before purge and owner close")
        #expect(
            !mobile.contains("photoBackup?.stopSync()"),
            "transient retry must not use the non-joining backup stop path")
        #expect(
            !mobile.contains("albumSync?.stopSync()"),
            "transient retry must not use the non-joining album stop path")
        let crawlStart = try Self.body(
            of: mobile,
            from: "func startLocationCrawlIfNeeded()",
            to: "func restartLocationCrawlIfNeeded()"
        )
        let joinedCrawl = try #require(crawlStart.range(of: "await crawl.cancel()"))
        let configuredStore = try #require(crawlStart.range(of: "store.configure(accountUID:"))
        #expect(
            joinedCrawl.upperBound <= configuredStore.lowerBound,
            "iOS must join the previous crawl before replacing the encrypted store lease")
        #expect(
            crawlStart.contains("locationCrawlInventoryRevision = max("),
            "the running crawl must acknowledge each refreshed inventory revision")

        let timeline = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileTimelineScreen.swift"),
            encoding: .utf8
        )
        #expect(
            timeline.contains("Task { await model.retry() }"),
            "the error action must await the model retry")

        let offline = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Offline/OfflineLibraryManager.swift"),
            encoding: .utf8
        )
        #expect(
            offline.contains("locationCrawlStartTask"),
            "the delayed macOS crawl starter must remain retained for teardown")
        #expect(
            offline.contains("await previousStarter?.value"),
            "macOS crawl replacement must join the previous delayed starter")
        #expect(
            offline.contains("await activeLocationCrawlStarter?.value"),
            "macOS account teardown must join the delayed crawl starter")
        #expect(
            offline.contains("accountUID: accountUID"),
            "macOS Core crawl runs must carry the configured account")

        let crawl = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/MediaLocationCore/LocationCrawl.swift"
            ),
            encoding: .utf8
        )
        #expect(
            crawl.contains("public func cancel() async"),
            "Core cancellation must join the active crawl")
        #expect(
            crawl.contains("generation"),
            "Core crawl state must carry a generation")
        #expect(
            crawl.contains("guard await current"),
            "Core must reject stale work around provider and publication awaits")
    }

    @Test func mapClusterViewerUsesClusterGridContext() throws {
        let mainView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Views/MainView.swift"), encoding: .utf8)
        #expect(
            mainView.contains("@State private var mapClusterGridProxy = GridProxy<PhotoUID>()"),
            "map cluster grid needs its own proxy so viewer open/close animations anchor to the tapped cluster cell")
        #expect(mainView.contains("proxy: mapClusterGridProxy"))
        #expect(mainView.contains("openPhoto(item, items, proxy: mapClusterGridProxy)"))
        #expect(mainView.contains("private var activeGridProxy: GridProxy<PhotoUID>"))
        #expect(mainView.contains("let preferredProxy = activeGridProxy"))
        #expect(mainView.contains("activeGridProxy.zoomOut?()"))
        #expect(mainView.contains("activeGridProxy.zoomIn?()"))
        #expect(mainView.contains("activeGridProxy.setContentMode?(gridContentMode)"))

        let clusterOverlay = try Self.body(
            of: mainView,
            from: "if selection == .map, mapClusterPresentation != nil {",
            to: "if let viewerModel, zoom == nil || zoom?.interactive == true {"
        )
        #expect(
            !clusterOverlay.contains(".frame(maxWidth:"),
            "the macOS cluster series must cover the full detail surface instead of exposing the map beside it")
        #expect(
            clusterOverlay.contains(".padding(.leading, leadingObstructionInset)"),
            "the root-ZStack cluster surface must move beside the expanded floating sidebar")
        #expect(
            clusterOverlay.contains(".animation(.easeInOut(duration: 0.3), value: leadingObstructionInset)"),
            "the cluster surface must track the animated floating-sidebar obstruction")
        #expect(
            clusterOverlay.contains(".ignoresSafeArea(.container, edges: [.top, .bottom])"),
            "the cluster surface must fill vertically without covering the leading sidebar")
        #expect(
            !clusterOverlay.contains(".environment(\\.gridLeadingEventInset, leadingObstructionInset)"),
            "the root-ZStack host already moves beside the sidebar and must not inset its Metal layout again")
        #expect(
            clusterOverlay.contains("gridProfile: TimelineGridProfiles.secondaryCollectionProfile"),
            "the macOS cluster grid must use the shared sparse-collection profile capped at three columns")

        let mobileCluster = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileMapClusterSeriesScreen.swift"),
            encoding: .utf8)
        let openBody = try Self.body(
            of: mobileCluster,
            from: "private func open(_ item: PhotoItem) {",
            to: "    private func startShare()"
        )
        #expect(
            openBody.contains("let items = clusterItems"),
            "iOS cluster viewer navigation must use the cluster's own ordered item list")
        #expect(openBody.contains("context: ViewerCollectionContext(filter: .map)"))
        #expect(
            !openBody.contains("model.items"),
            "opening a cluster item against the full library breaks the cluster viewer context")
        #expect(
            mobileCluster.contains(".task(id: \"\\(model.timelineRevision)-\\(pageIndex)\")"),
            "the iOS cluster projection should refresh only after a timeline publication or bounded page change")
        #expect(
            !mobileCluster.contains("model.selectedItems(Set(uids)).sorted"),
            "the indexed snapshot is already canonical; body updates must not re-project and re-sort it")
    }

    @Test func viewerUsesBoundedOriginalStreamingAndKeepsCacheWritesFenced() throws {
        let mainView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Views/MainView.swift"), encoding: .utf8)
        #expect(mainView.contains("originalsCache: offline.originalsCache"))
        #expect(mainView.contains("cacheOriginals: offline.offlineEnabled"))
        #expect(mainView.contains("originalsCapBytes: offline.originalsCapBytes"))

        let viewer = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/PhotoViewerModel.swift"), encoding: .utf8)
        #expect(
            viewer.contains("OriginalByteStreamProvider"), "viewer must use the bounded original byte-stream capability"
        )
        #expect(
            !viewer.contains("oc.diskData(for: uid)"),
            "page appearance must not decrypt a full cached original before a bounded request")
        #expect(
            viewer.contains("oc.storeToDisk(data, for: uid, ifCurrent: originalWriterGeneration)"),
            "viewer must persist downloaded originals only for the active cache generation")
        #expect(
            viewer.contains("oc.enforceByteCap(cap, ifCurrent: originalWriterGeneration)"),
            "viewer must enforce the originals LRU budget only for the active cache generation")
        #expect(
            viewer.contains("previewCache.storeToDisk(data, for: uid, ifCurrent: previewGeneration)"),
            "viewer preview writes must reject data from an older cache generation")
        #expect(
            viewer.contains("requestOriginal(maxPixelSize:"),
            "the bounded original tier must be explicitly demand-driven")
        #expect(viewer.contains("decodeStreamedImage"), "viewer decoding must consume streamed chunks")
        #expect(
            viewer.contains("motion.play(for: item, streamer: streamer)"),
            "Live Photo motion preparation must begin from an explicit user request")
        #expect(
            !viewer.contains("motion.prepare(for: item, streamer: streamer)"),
            "ordinary page appearance must not preload Live Photo motion")

        let offline = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Offline/OfflineLibraryManager.swift"), encoding: .utf8
        )
        #expect(offline.contains("originalsCache.clearForSignOut()"), "sign-out purge must include originals")
        #expect(
            offline.contains("func purgeOriginalsCache() async"),
            "turning offline off must have an originals-only purge")
        #expect(offline.contains("await originalsCache.clear()"))
    }

    @Test func viewerNeverPersistsDecryptedMotionVideoTempFiles() throws {
        let motion = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerCore/LivePhotoMotionController.swift"),
            encoding: .utf8)
        #expect(
            !motion.contains("temporaryDirectory"), "Live Photo motion must not write decrypted video bytes to /tmp")
        #expect(!motion.contains("proton-motion-"), "Live Photo motion must not synthesize plaintext local movie files")
        #expect(!motion.contains("AVPlayer(url:"), "Viewer playback must not rely on decrypted local temp files")
        #expect(motion.contains("private var asset: StreamingVideoAsset?"))
        #expect(motion.contains("streamer.makeStreamingAsset(for: motionUID)"))
        #expect(motion.contains("AVPlayerItem(asset: stream.asset)"))
    }

    @Test func videoBlockCacheStoreDoesNotWalkWholeTreePerBlock() throws {
        let cache = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/Streaming/VideoByteRangeCache.swift"),
            encoding: .utf8)
        let storeBody = try Self.body(
            of: cache, from: "@discardableResult\n    func store(", to: "    /// Clears the whole video block cache")
        #expect(storeBody.contains("sizeOnDiskLocked()"), "store must initialize from the cached size tracker")
        #expect(
            storeBody.contains("enforceBudgetLocked(keep:"), "store must enforce budget from the cached size tracker")
        #expect(
            !storeBody.contains("directorySize(root)"),
            "store must not rescan the full video cache tree for every block")
        #expect(
            cache.contains("writerGeneration.invalidateAndPerform"),
            "video clear must advance the writer generation atomically with deletion")
        #expect(
            cache.contains("struct Lookup: Sendable"),
            "each video miss must receive an explicit per-request cache ticket")
        #expect(
            cache.contains("ticket: CacheWriterGeneration.Token"),
            "video stores must require the exact ticket captured by their lookup")
        #expect(
            cache.contains("guard ticket == ownerGeneration else { return false }"),
            "video stores must reject a post-clear lookup presented by an older loader owner")
        #expect(
            cache.contains("writerGeneration.performIfCurrent(ownerGeneration)"),
            "video stores must fence the complete write against the loader owner's generation")

        let budgetBody = try Self.body(
            of: cache,
            from: "private func enforceBudgetLocked(keep: String, ticket: CacheWriterGeneration.Token) {",
            to: "private func sizeOnDiskLocked()"
        )
        #expect(
            budgetBody.contains("var total = sizeOnDiskLocked()"),
            "budget enforcement must consume the running size tracker")

        let loader = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/Streaming/ProtonVideoResourceLoader.swift"),
            encoding: .utf8)
        #expect(
            loader.contains("await cache.lookupAsync"),
            "range serving must keep filesystem reads off the cooperative executor")
        #expect(
            loader.contains("await cache.storeAsync"),
            "range serving must keep filesystem writes off the cooperative executor")
        #expect(loader.contains("prefetchTasks.removeAll()"), "a cancelled request must invalidate stale read-ahead")
    }

    @Test func burstProviderMaterializesHiddenSeriesMembers() throws {
        let bridge = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift"), encoding: .utf8)
        let body = try Self.body(
            of: bridge, from: "func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] {",
            to: "    // MARK: - VideoStreamProvider")
        #expect(
            body.contains("Self.syntheticBurstMember("),
            "Proton exposes series as one visible timeline photo plus hidden RelatedPhotos; the viewer must materialize those hidden members"
        )
        #expect(
            !body.contains("return memberIDs.compactMap"),
            "Do not collapse a real Proton series to only members already present in the normal timeline")
        #expect(
            bridge.contains("private static func syntheticBurstMember("),
            "UID-backed synthetic members let thumbnail/preview/original loading use the existing provider path")
        #expect(
            body.contains("if let cached = burstCatalogEntries"),
            "a complete burst catalog must not be scanned again for a missing UID")
    }

    @Test func mainViewUsesNativeSplitViewChrome() throws {
        let mainView = Self.repoRoot.appendingPathComponent("App/Views/MainView.swift")
        let text = try String(contentsOf: mainView, encoding: .utf8)
        // The library shell is a native NavigationSplitView: the floating sidebar overlays the detail, whose
        // MTKView renders full-WIDTH under it (`.ignoresSafeArea(.container, edges: [..., .leading])`). The grid
        // is laid out only in the unobscured area via a leading OBSTRUCTION INSET driven by the detail's leading
        // safe-area inset. The hand-rolled overlay ZStack + the custom drag-resize handle are gone (native
        // resize + the native toolbar toggle replace them). The invariants:
        #expect(text.contains("NavigationSplitView("))  // native split view shell
        #expect(text.contains(".navigationSplitViewColumnWidth("))  // native column-width policy
        #expect(text.contains(".smartSearchToolbar("))  // shared, settings-gated native search
        #expect(text.contains("@State private var committedSearchText"))  // UI input is debounced before filtering
        #expect(text.contains("Task.sleep(for: .milliseconds(280))"))
        #expect(text.contains("searchText: committedSearchText"))
        #expect(
            text.contains("isSearchPending: isCommittedSemanticSearchPending"),
            "only an in-flight semantic result for the committed query may hide lexical fallback content")
        #expect(text.contains(".ignoresSafeArea(.container"))  // detail extends under the floating sidebar
        // The obstruction inset is derived from the KNOWN sidebar width gated on columnVisibility - SwiftUI
        // coordinate spaces / preferences don't bridge across NavigationSplitView's AppKit sidebar, so it can't be
        // measured. It must not wrap the grid in a GeometryReader (the per-tick resize throttle).
        #expect(text.contains("columnVisibility == .detailOnly ? 0 : sidebarWidth"))  // obstruction-inset source
        #expect(text.contains("gridLeadingEventInset"))  // inset threaded to the Metal grid host
        #expect(text.contains(".encryptedMemoriesToggleSidebar"))  // ⌥⌘S receiver kept
        #expect(
            !text.contains(".toolbar(removing: .sidebarToggle)"),
            "NavigationSplitView must own the native sidebar item in its sidebar title-bar region")
        #expect(
            !text.contains("Label(\"menu.toggle_sidebar\", systemImage: \"sidebar.left\")"),
            "do not duplicate the native sidebar item in the detail toolbar")
        #expect(
            text.contains(".navigationTitle(viewerModel == nil ? title : \"\")"),
            "the current library route must remain the native navigation title")
        #expect(
            text.contains("ToolbarItem(placement: .navigation) {\n            Text(title)"),
            "the native route-title toolbar item must remain structurally mounted")
        #expect(
            text.contains(".hidden(viewerModel != nil)"),
            "the title must use native toolbar visibility instead of structural removal")
        #expect(
            text.contains(".hidden(viewerModel == nil && !(selection == .map && mapClusterPresentation != nil))"),
            "the back item must use native toolbar visibility instead of structural removal")
        #expect(
            text.contains(".sharedBackgroundVisibility(.visible)"),
            "the route title and back control must remain one system-owned Liquid Glass shape")
        #expect(
            text.contains(".animation(navigationChromeAnimation, value: navigationChromeState)"),
            "Map, cluster, and viewer state changes must animate the native toolbar geometry")
        #expect(
            text.contains(".contentTransition(.interpolate)"),
            "route-title changes should use SwiftUI's native content interpolation")
        #expect(
            text.contains("reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0)"),
            "toolbar geometry motion must be disabled when Reduce Motion is enabled")
        #expect(
            text.contains(".fixedSize(horizontal: true, vertical: false)"),
            "the title must not be compressed inside its Liquid Glass capsule")
        #expect(
            text.contains(".padding(.horizontal, 12)"),
            "the title capsule must reserve visible horizontal breathing room")
        #expect(
            text.contains("ToolbarItemGroup(placement: .principal)"),
            "common grid controls belong in the centered principal toolbar region")
        #expect(
            text.contains("ToolbarItemGroup(placement: .secondaryAction)"),
            "selection actions belong in the secondary region alongside the system search field")
        #expect(
            !text.contains("ToolbarSpacer(.flexible)"),
            "a rejected flexible-space workaround must not remain in the toolbar")
        #expect(
            text.contains("_columnVisibility = State(initialValue: .all)"),
            "the native sidebar track must mount before a persisted hidden state is restored")
        #expect(
            text.contains("restoreInitialSidebarVisibilityIfNeeded()"),
            "a persisted hidden sidebar must be restored under the launch cover, not before AppKit mounts")
        #expect(!text.contains("ZStack(alignment: .topLeading)"))  // the hand-rolled overlay layout is gone
        #expect(!text.contains("SidebarPersistence.saveWidth"))  // no custom drag-resize handle (native resize)
    }

    @Test func liquidGlassChromeUsesNativeContracts() throws {
        let app = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/EncryptedMemoriesApp.swift"), encoding: .utf8)
        #expect(
            app.contains(".windowStyle(.hiddenTitleBar)"),
            "the scene must remove AppKit's title-bar backing so the launch material covers the full window")
        #expect(
            app.contains(".windowToolbarStyle(.unified)"), "window chrome should stay on the native unified toolbar")
        #expect(
            app.contains(".launchVeil(purpose: model.launchVeilPurpose, model: model)"),
            "startup and sign-out must use the native launch veil instead of a black loading screen")
        #expect(
            app.contains(".toolbarVisibility(visible ? .hidden : .automatic, for: .windowToolbar)"),
            "SwiftUI must own launch-time toolbar visibility so it remains synchronized with scene chrome")
        #expect(
            app.contains("override func viewDidMoveToWindow()"),
            "window lifecycle controllers must attach synchronously when the representable reaches its window")
        #expect(
            !app.contains("DispatchQueue.main.async { configure("),
            "deferring window lifecycle attachment creates a race on first presentation")
        #expect(
            !app.contains("WindowChromeVisibility"),
            "a rejected AppKit chrome workaround must not remain underneath the native scene contract")
        #expect(
            !app.contains("titlebarAppearsTransparent"),
            "SwiftUI can rebuild title-bar backing after imperative AppKit mutation")
        #expect(
            !app.contains("window.toolbar?.isVisible"),
            "toolbar visibility must not be split between SwiftUI and an AppKit state cache")
        #expect(
            !app.contains(".preferredColorScheme(.dark)"),
            "the app must not globally lock native Liquid Glass to dark mode")

        #expect(
            app.contains("LibraryWindowVisibilityController.shared.attach(to: window)"),
            "the library window must stay mounted when its red close control is used")
        #expect(
            app.contains("applicationShouldTerminateAfterLastWindowClosed"),
            "closing the last window must keep the macOS process alive until the user quits")
        #expect(
            app.contains("func applicationShouldHandleReopen"),
            "Dock activation must route through the native AppKit reopen callback")
        #expect(
            app.contains("sender.activate()"),
            "Dock activation must reactivate the running app before revealing the library")
        #expect(
            app.contains("return false\n    }\n\n    func applicationDockMenu"),
            "the handled reopen event must not fall through to AppKit's default scene creation")
        #expect(
            app.contains("func windowShouldClose(_ sender: NSWindow) -> Bool"),
            "the native close decision must be intercepted after SwiftUI rebuilds toolbar chrome")
        #expect(
            app.contains("sender.orderOut(nil)\n        return false"),
            "closing the library must hide its existing AppKit window instead of destroying SwiftUI state")
        #expect(
            app.contains("forwardingTo: window.delegate"),
            "the close proxy must preserve SwiftUI's other NSWindowDelegate behavior")
        #expect(
            !app.contains("closeButton.target = self"),
            "a rejected close-button target override must not remain beneath the delegate contract")
        #expect(
            app.contains("LibraryWindowVisibilityController.shared.showLibrary()"),
            "Command-1 and Dock reopen must reveal the retained window before asking SwiftUI for a scene")
        #expect(
            app.contains("window.makeKeyAndOrderFront(nil)"),
            "reopening the library must foreground the retained window")
        #expect(
            app.contains("func applicationDockMenu(_ sender: NSApplication) -> NSMenu?"),
            "the Dock menu must expose the retained library window explicitly")
        #expect(
            app.contains("action: #selector(showLibraryFromDock(_:))"),
            "the Dock library action must use the dedicated native AppKit route")

        let mainView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Views/MainView.swift"), encoding: .utf8)
        #expect(mainView.contains("TopFrostBar("), "Metal-backed grid needs the shared within-window frost bar")
        #expect(
            !mainView.contains("SidebarGridEdgeFade"),
            "the native floating-sidebar boundary must not gain a painted overlay above the Metal grid")
        // The within-window frost bridge now lives in the cross-platform DesignSystemCore component shared
        // with iOS, not inline in MainView.
        let frost = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/DesignSystemCore/TopFrostBar.swift"), encoding: .utf8)
        #expect(
            frost.contains("NSVisualEffectView()"),
            "toolbar frost must use public AppKit material, not painted rectangles")
        #expect(frost.contains("blendingMode = .withinWindow"), "frost must sample the Metal grid inside the window")
        #expect(
            frost.contains("state = .followsWindowActiveState"),
            "active/inactive toolbar vividness must remain system-driven")
        #expect(
            frost.contains("@Environment(\\.libraryLoadingCoverPresented)"),
            "toolbar frost must stay absent until the shared launch cover begins to dissolve")
        #expect(
            frost.contains("effect.effect = isActive ? UIBlurEffect"),
            "UIKit frost must animate its effect instead of alpha-fading a visual-effect hierarchy")
        #expect(mainView.contains(".smartSearchToolbar("), "search must use the shared native toolbar policy")
        #expect(
            mainView.contains("snapshot.isSearchAvailable == true"),
            "macOS search must appear only after the enabled index can answer queries")
        #expect(mainView.contains("LibraryActivityBannerOverlay("))
        #expect(
            mainView.contains("leadingObstructionInset: leadingObstructionInset"),
            "macOS activity status must center inside the unobscured grid, not the whole window")
        #expect(
            mainView.contains("LibraryConnectivityBannerState.resolve("),
            "macOS connectivity and library work must share the same stable bottom banner")
        #expect(
            !mainView.contains("private var offlineIndicator"),
            "offline state must not create a second platform-specific pill")
        #expect(
            mainView.contains("backgroundLibraryActivityActive && viewerModel == nil && selection.hasTimeline"),
            "background library activity belongs only over a visible timeline grid")
        #expect(!mainView.contains("libraryPreparePill"))
        #expect(
            !mainView.contains("isLibraryToolbarActivityActive"),
            "routine synchronization and background processing must not occupy macOS toolbar chrome")
        let offlineManager = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Offline/OfflineLibraryManager.swift"),
            encoding: .utf8
        )
        #expect(
            offlineManager.contains("thumbnailUpdateCoordinator.reconcile("),
            "macOS must route authoritative additions through the shared thumbnail-batch coordinator")
        #expect(
            !offlineManager.contains("locationProgress:"),
            "location indexing must never drive the library update banner")
        let mobileTimeline = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileTimelineScreen.swift"),
            encoding: .utf8
        )
        let mobileApp = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/EncryptedMemoriesMobileApp.swift"),
            encoding: .utf8
        )
        let adaptiveShell = sourceBlock(
            from: "private struct MobileAdaptiveTabShell: View",
            to: "private struct MobileSearchTabScreen: View",
            in: mobileApp
        )
        let searchTabScreen = sourceBlock(
            from: "private struct MobileSearchTabScreen: View",
            to: "private struct MobileUnsupportedDeviceView: View",
            in: mobileApp
        )
        #expect(
            mobileApp.contains("Tab(value: MobileTab.search, role: .search)"),
            "iOS and iPadOS search must use the native semantic search-tab role")
        #expect(
            mobileApp.contains(".tabViewSearchActivation(.searchTabSelection)"),
            "selecting the semantic search tab must activate its native search field")
        #expect(
            !adaptiveShell.isEmpty && !searchTabScreen.isEmpty,
            "the source guard must resolve both mobile search ownership boundaries")
        #expect(
            !adaptiveShell.contains(".searchable(") && !adaptiveShell.contains(".smartSearchScopes("),
            "outer TabView search modifiers create permanent search chrome on non-search tabs")
        #expect(
            searchTabScreen.contains(".searchable(\n            text: $searchText"),
            "the semantic searchable must belong to the search tab's own navigation content")
        #expect(
            searchTabScreen.contains(".smartSearchScopes("),
            "the search tab must reuse the shared native scope policy without wrapping searchable")
        #expect(
            mobileApp.components(separatedBy: ".searchable(").count - 1 == 1,
            "the mobile root shell must expose exactly one native search surface")
        #expect(
            !mobileApp.contains(".smartSearchToolbar("),
            "a toolbar-search wrapper on TabView renders ordinary top search chrome")
        #expect(
            !mobileApp.contains("--search-tab-diagnostic") && !mobileApp.contains("Search-tab baseline"),
            "temporary search diagnostics must not remain reachable in production")
        #expect(
            mobileApp.contains("snapshot.isSearchAvailable == true"),
            "mobile search must appear only after the enabled index can answer queries")
        #expect(
            mobileTimeline.contains("semanticQuery?.isSearching == true"),
            "mobile must not flash lexical or empty intermediate search results")
        #expect(
            mobileTimeline.contains(".overlay { overlay }"),
            "mobile status overlays must be centered over the resolved timeline bounds")
        #expect(mobileTimeline.contains("LibraryActivityBannerOverlay("))
        #expect(
            mobileTimeline.contains("LibraryConnectivityBannerState"),
            "iOS and iPadOS connectivity and library work must share the same stable bottom banner")
        #expect(
            !mobileTimeline.contains("model.isRefreshingLibrary ||"),
            "the five-second comparison must not flash a title spinner on iOS or iPadOS")
        let mobileLibrary = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileLibraryModel.swift"),
            encoding: .utf8
        )
        #expect(
            mobileLibrary.contains("thumbnailUpdateCoordinator.reconcile("),
            "iOS and iPadOS must route authoritative additions through the shared thumbnail-batch coordinator")
        #expect(
            !mobileLibrary.contains("locationProgress:"),
            "location indexing must never drive the library update banner")
        let activityPolicy = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/TimelineCore/LibraryThumbnailUpdateCoordinator.swift"
            ),
            encoding: .utf8
        )
        #expect(
            activityPolicy.contains("currentUIDs: [PhotoUID]") && activityPolicy.contains("addedUIDs: [PhotoUID]"),
            "library activity must be derived from a concrete authoritative inventory delta")
        #expect(
            activityPolicy.contains("No deadline can hide genuine thumbnail work"),
            "new-asset thumbnail progress must not disappear behind an arbitrary timeout")
        #expect(
            !activityPolicy.contains("PhotoLocation") && !activityPolicy.contains("visibleUntil"),
            "location work and trailing timers must stay outside the new-asset thumbnail contract")
        #expect(
            !activityPolicy.contains("MLSearch"),
            "Smart Search indexing must not drive the general library activity banner")
        let smartSearchToolbar = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/MLSearchFeature/SmartSearchToolbar.swift"
            ),
            encoding: .utf8
        )
        #expect(
            !smartSearchToolbar.contains(".toolbar(removing: isEnabled ? nil : .search)"),
            "Smart Search availability must not remove the always-available lexical library search")
        #expect(
            smartSearchToolbar.contains(".toolbar(removing: isVisible ? nil : .search)"),
            "viewer chrome must hide only the search toolbar item while preserving the grid view identity")
        #expect(
            !smartSearchToolbar.contains("if !isVisible"),
            "viewer chrome must not replace the searchable content branch and recreate the Metal grid host")
        #expect(
            smartSearchToolbar.contains(".searchToolbarBehavior(.minimize)"),
            "enabled search should use Apple's compact expanding toolbar treatment")
        #expect(
            smartSearchToolbar.contains(".searchScopes($scope, activation: .onTextEntry)"),
            "macOS, iOS and iPadOS must use Apple's visible native search-scope presentation")
        #expect(
            smartSearchToolbar.contains("availableScopes.count > 1"),
            "a single available search backend must not create a meaningless scope bar")
        #expect(
            smartSearchToolbar.contains("reconcileSearchQueryChange(from: oldQuery, to: newQuery)"),
            "native search must distinguish initial empty focus from an X-driven clear transition")
        #expect(
            smartSearchToolbar.contains("func smartSearchScopes("),
            "semantic search tabs must be able to reuse scope policy without wrapping searchable")
        #expect(
            smartSearchToolbar.components(separatedBy: ".searchable(").count - 1 == 1,
            "the shared toolbar path must contain exactly one ordinary searchable")
        #expect(
            smartSearchToolbar.contains("isPresented = false"),
            "clearing the query must dismiss Apple's scope presentation instead of leaving stale filters")
        #expect(
            !smartSearchToolbar.contains(".onChange(of: isPresented)"),
            "collapsing a populated search field must retain its selected scope")
        #expect(
            !smartSearchToolbar.contains(".dismiss(clearText: true)"),
            "unavailable Smart Search must not reject ordinary lexical library queries")
        #expect(
            !smartSearchToolbar.contains("tokens:"),
            "the primary search scope must not be a deletable token")
        #expect(
            !smartSearchToolbar.contains("SearchScopeToken"),
            "the rejected token workaround must be removed completely")
        #expect(
            !smartSearchToolbar.contains("if isEnabled {"),
            "availability changes must not switch the navigation container's structural branch")
        #expect(
            mainView.contains(".alert(trashConfirmationTitle"),
            "binary destructive confirmations need a native alert instead of an anchored menu")
        #expect(mainView.contains("if albumActions.loadErrorMessage == nil"))
        #expect(
            !mainView.contains("albums = (try? await backend.albums()) ?? []"),
            "a transient album refresh failure must preserve the last authoritative catalog")
        #expect(
            sourceBlock(
                from: "private func retryAfterConnectivityRestored()",
                to: "private var gridFillOrder",
                in: mainView
            ).contains("Task { await loadAlbums() }"),
            "connectivity recovery must retry the album catalog too")
        #expect(
            sourceBlock(
                from: "private func retryAfterConnectivityRestored()",
                to: "private var gridFillOrder",
                in: mainView
            ).contains("model.refreshLibrarySources()"),
            "connectivity recovery must retry additional library-source discovery")
        #expect(mainView.contains("Label(\"sidebar.map\""), "Map must be localized on macOS")
        #expect(
            !mainView.contains("try? await facade.albums.setAlbumCover"),
            "album-cover failures must remain visible instead of being discarded")
        #expect(mainView.containsCodeFragmentIgnoringWhitespace("albumCoverFailureMessage = String(localized:"))
        #expect(
            mainView.contains("selectedUIDs.count != 1 || isSettingAlbumCover"),
            "repeated cover taps must not create competing writes")
        #expect(
            mainView.contains("exportFailureMessage = String(localized:"),
            "export failures must produce a native user-visible alert")
        #expect(
            !mainView.contains("let alert = NSAlert()"),
            "export errors must use the view's native SwiftUI alert presentation")
        #expect(
            mainView.contains("ViewerMutationPolicy.action(for: ViewerCollectionContext(filter: selection))"),
            "viewer mutations must reflect the collection that opened the viewer")
        #expect(
            mainView.contains("restorePhotos([item], closeViewer: true)"),
            "a restored trash item must close its stale trash viewer")
        let viewerView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/PhotoViewerView.swift"), encoding: .utf8)
        #expect(
            !viewerView.contains("onTrash"),
            "the viewer's destructive action is owned by the host mutation policy, not a dead callback")
        #expect(
            viewerView.contains("model.videoState.isBusy && !model.videoState.hasPlayer"),
            "macOS must not stack its own round spinner over AVKit's native player-loading spinner")
        #expect(
            mainView.contains("allLibraryItems(matching: Set(page.uids))"),
            "Map cluster pages must resolve only their bounded UID page from the whole-library index")
        #expect(!mainView.contains("uniquePhotoUIDs(uids)"))
        #expect(
            !mainView.contains(".sorted(by: TimelineOrder.areInIncreasingOrder)"),
            "Map clusters are already canonical and must not be sorted again on the main actor")
        let viewerModel = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/PhotoViewerModel.swift"), encoding: .utf8)
        #expect(
            !viewerModel.contains("let meta = try? await metadataProvider.metadata"),
            "metadata failures must not become an eternal nil/loading state")
        #expect(viewerModel.contains("metadataLoadState = .failed"))
        #expect(viewerModel.contains("public func retryMetadata()"))
        #expect(
            viewerModel.contains("albumMembershipProvider.albumMembershipTitles"),
            "the macOS viewer inspector must expose SDK album memberships")
        let timelineView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/TimelineFeature/TimelineView.swift"), encoding: .utf8)
        #expect(
            !timelineView.contains("TimelineSearch.filter("),
            "macOS must never scan the full library synchronously during view rendering")
        #expect(
            !mobileTimeline.contains("TimelineSearch.filter("),
            "iOS must never scan the full library synchronously during view rendering")
        #expect(timelineView.contains("searchCoordinator.resolve(sections: sections, key: key)"))
        #expect(mobileTimeline.contains("searchCoordinator.resolve(sections: sections, key: key)"))
        #expect(
            mobileTimeline.contains("TimelineSearchContext(favoriteUIDs: model.favoriteUIDs)"),
            "mobile Favorites search needs the authoritative server identities")
        #expect(
            timelineView.contains("if isSearchResultPending"),
            "search loading must overlay the retained Metal grid instead of unmounting it")
        let smartSearch = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/MLSearchCore/MLSmartSearchController.swift"), encoding: .utf8)
        #expect(
            smartSearch.contains("public private(set) var resolvedQuery: String?"),
            "semantic matches must carry the exact query identity that produced them")
        #expect(
            !smartSearch.contains("requestedQuery = trimmed\n        resolvedQuery = nil"),
            "typing must retain the semantic result owned by the previous committed query")
        let searchProjection = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/TimelineCore/TimelineSearchProjection.swift"), encoding: .utf8)
        #expect(
            searchProjection.contains("withTaskCancellationHandler"),
            "cancelling a view task must cancel its detached whole-library scan")
        #expect(
            searchProjection.contains("cachedProjection = nil"),
            "closing search must release its duplicate full-library projection")
        #expect(
            !mainView.contains(".toolbarBackground("),
            "custom toolbar backgrounds box the sidebar and fight Liquid Glass")
        #expect(!mainView.contains("gridToolbarGlassFade"), "old hand-painted toolbar gradient must not return")
        #expect(!mainView.contains("SidebarResizeHandle"), "the custom sidebar resize handle must not return")
        #expect(
            mainView.contains("SettingsLink"),
            "macOS settings must remain discoverable from the visible sidebar")

        let settingsView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Views/SettingsView.swift"), encoding: .utf8)
        #expect(
            settingsView.contains(".navigationTitle(\"sidebar.settings\")"),
            "the Settings window title must remain Settings instead of following the active tab into the Dock menu")
        #expect(settingsView.contains("@Environment(\\.dismissWindow)"))
        let dismissCall = settingsView.range(of: "dismissWindow()")
        let signOutCall = settingsView.range(of: "signOut()")
        #expect(
            dismissCall != nil && signOutCall != nil && dismissCall!.lowerBound < signOutCall!.lowerBound,
            "macOS Settings must close before account teardown begins")
        #expect(
            !settingsView.contains("Timer.publish("),
            "diagnostics must refresh on explicit demand instead of polling while Settings stays open")
        #expect(
            settingsView.contains("guard !refreshing else { return }"),
            "manual and automatic diagnostics refreshes must not overlap")

        let colors = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/DesignSystemCore/ProtonColors.swift"), encoding: .utf8)
        #expect(colors.contains("Color(nsColor: .windowBackgroundColor)"), "neutral backgrounds should stay semantic")
        #expect(
            colors.contains("public static let textNorm = Color.primary"), "foreground neutrals should stay semantic")

        let components = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/DesignSystemCore/ProtonComponents.swift"), encoding: .utf8)
        #expect(!components.contains("struct ProtonPrimaryButtonStyle"), "dead custom button style must not return")
        #expect(!components.contains("struct ProtonSpinner"), "dead custom spinner must not return")

        let timeline = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/TimelineFeature/TimelineView.swift"), encoding: .utf8)
        #expect(
            timeline.contains("ContentUnavailableView"),
            "grid empty/error/search states should use native unavailable views")

        let uploadQueue = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/UploadFeature/UploadQueuePanel.swift"), encoding: .utf8)
        #expect(
            uploadQueue.contains("ContentUnavailableView"),
            "upload queue empty state should use native unavailable view")
        #expect(
            !uploadQueue.contains(".background(.regularMaterial)"),
            "popover content must not stack a second material over native popover glass")
    }

    @Test func librarySourceRuntimeKeepsVersionedInventoryAndRecoveryRoutes() throws {
        let appModel = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/AppModel.swift"),
            encoding: .utf8
        )
        let mainView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Views/MainView.swift"),
            encoding: .utf8
        )
        let mobileApp = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/EncryptedMemoriesMobileApp.swift"),
            encoding: .utf8
        )
        let mobileLibrary = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileLibraryModel.swift"),
            encoding: .utf8
        )

        #expect(
            appModel.components(separatedBy: "generation: primaryGeneration").count - 1 >= 2,
            "macOS startup and later primary-inventory updates must share the monotonic generation fence"
        )
        #expect(
            mobileLibrary.contains("generation: primaryGeneration"),
            "iOS and iPadOS primary-inventory updates must use the same generation fence"
        )

        let mobileSourceConfiguration = sourceBlock(
            from: "private func configureSourceAnalysis(",
            to: "/// Stops Smart Search",
            in: mobileLibrary
        )
        #expect(
            !mobileSourceConfiguration.contains("_ = await runtime.start()"),
            "mobile must not bind an empty source scope while the first timeline inventory is already loading"
        )

        let mobileInventoryPublication = sourceBlock(
            from: "private func applyItems(",
            to: "private func publish(",
            in: mobileLibrary
        )
        #expect(mobileInventoryPublication.contains("await synchronizePrimarySourceInventory("))
        #expect(mobileInventoryPublication.contains("if changed {"))
        #expect(
            mobileInventoryPublication.range(of: "await synchronizePrimarySourceInventory(")!.lowerBound
                < mobileInventoryPublication.range(of: "if changed {")!.lowerBound,
            "primary membership must authorize the feed before any first grid frame is published"
        )

        let macConnectivityRecovery = sourceBlock(
            from: "private func retryAfterConnectivityRestored()",
            to: "private var gridFillOrder",
            in: mainView
        )
        #expect(macConnectivityRecovery.contains("model.refreshLibrarySources()"))

        let macRemoteRefresh = sourceBlock(
            from: "@MainActor private func performRemoteLibraryRefresh()",
            to: "private func scheduleLibraryRefreshAfterBackupUpload()",
            in: mainView
        )
        #expect(macRemoteRefresh.contains("model.refreshLibrarySources()"))

        #expect(
            mobileApp.contains("libraryModel.refreshLibrarySources()"),
            "mobile connectivity recovery must refresh additional library sources"
        )
        let mobileRemoteRefresh = sourceBlock(
            from: "private func performLibraryRefresh(",
            to: "private func apply(_ event: LibraryLoadEvent)",
            in: mobileLibrary
        )
        #expect(
            mobileRemoteRefresh.contains("refreshLibrarySources()"),
            "mobile remote-library changes must refresh additional library sources"
        )
    }

    @Test func mobileColdFailureKeepsAutomaticInventoryRecovery() throws {
        let mobileLibrary = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileLibraryModel.swift"),
            encoding: .utf8
        )
        let failure = sourceBlock(
            from: "if error is SourceAnalysisStartupError {",
            to: "/// Builds an immutable",
            in: mobileLibrary
        )
        #expect(failure.contains("initialLibraryLoadSettled = true"))
        #expect(failure.contains("startLibraryChangeMonitorIfPossible(resetBaseline: true, initialToken: \"\")"))
        #expect(!failure.contains("if hadCachedInventory"))
        let monitor = sourceBlock(
            from: "private func startLibraryChangeMonitorIfPossible(",
            to: "private func requestLibraryRefresh()",
            in: mobileLibrary
        )
        #expect(monitor.contains("loadState.failure?.retryable == true ? \"\" : nil"))
        #expect(monitor.contains("initialToken: initialToken"))
    }

    @Test func liquidGlassAvailabilityStaysCentralized() {
        let roots = [
            Self.repoRoot.appendingPathComponent("App"),
            Self.repoRoot.appendingPathComponent("iOSApp"),
            Self.repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Sources"),
        ]
        var scanned = 0
        for root in roots {
            for file in swiftFiles(under: root) {
                scanned += 1
                guard file.lastPathComponent != "AdaptiveGlass.swift" else { continue }
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                for token in [".glassEffect", ".buttonStyle(.glass"] {
                    #expect(
                        !text.contains(token),
                        "\(token) must stay behind DesignSystemCore/AdaptiveGlass.swift: \(file.path)")
                }
            }
        }
        #expect(scanned > 0, "Guard scanned no files - repoRoot path is wrong: \(Self.repoRoot.path)")
    }

    @Test func albumsSidebarAndEmptyRoutesStayExplicit() throws {
        let mainView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Views/MainView.swift"), encoding: .utf8)
        let sidebar = try Self.body(
            of: mainView, from: "private struct SidebarView: View", to: ".scrollContentBackground(.hidden)")
        #expect(
            sidebar.contains("Section(\"sidebar.albums\")"),
            "the Albums section must stay visible even before the account has albums")
        #expect(sidebar.contains("if albums.isEmpty"))
        #expect(sidebar.contains("Label(\"sidebar.no_albums\", systemImage: \"tray\")"))
        #expect(sidebar.contains(".disabled(true)"), "the empty-albums row is information, not a fake route")
        #expect(
            !sidebar.contains("if !albums.isEmpty"),
            "hiding the whole Albums section makes 'no albums' indistinguishable from a broken album fetch")
        #expect(
            sidebar.contains("SettingsLink"),
            "settings must use a native list row so it aligns and scrolls without overlapping routes")
        #expect(
            sidebar.contains("Divider()\n                SettingsLink"),
            "a native divider must distinguish app settings from library and album routes")
        #expect(
            sidebar.contains(".buttonStyle(.plain)"),
            "SettingsLink's default macOS button chrome adds a gray capsule and extra indentation")
        #expect(
            !mainView.contains(".safeAreaInset(edge: .bottom"),
            "an overlaid settings footer can cover the final sidebar routes in short windows")

        let appStrings = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/Localizable.xcstrings"), encoding: .utf8)
        #expect(appStrings.contains("\"sidebar.no_albums\""))

        let timeline = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/TimelineFeature/TimelineView.swift"), encoding: .utf8)
        let mobileAlbums = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileAlbumsScreen.swift"), encoding: .utf8)
        let mobileStateViews = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileLibraryStateViews.swift"), encoding: .utf8)
        let photoLibrary = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotosCore/PhotoLibrary.swift"), encoding: .utf8)
        #expect(timeline.contains("private var emptyStateCopy"))
        #expect(
            timeline.contains("model.filter.emptyStateCopy"),
            "macOS timeline empty copy must come from the shared PhotoFilter policy")
        #expect(
            mobileAlbums.contains("filter.emptyStateCopy"),
            "iOS filtered routes, including Trash, must use the shared PhotoFilter empty copy")
        #expect(
            mobileStateViews.contains("PhotoFilter.all.emptyStateCopy"),
            "iOS all-photos empty state must use the shared PhotoFilter empty copy")
        #expect(
            !mobileAlbums.contains("collections.filter_empty"),
            "iOS must not maintain a second generic filtered-empty string")
        #expect(!mobileStateViews.contains("empty.title"))
        #expect(!mobileStateViews.contains("empty.message"))
        #expect(photoLibrary.contains("public struct PhotoFilterEmptyStateCopy"))
        #expect(photoLibrary.contains("public extension PhotoFilter"))
        #expect(photoLibrary.contains("empty.album_title"))
        #expect(photoLibrary.contains("empty.filter_title"))
        #expect(photoLibrary.contains("empty.trash_title"))

        let packageStrings = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotosCore/Resources/Localizable.xcstrings"), encoding: .utf8)
        for key in [
            "empty.album_title", "empty.album_description", "empty.filter_title %@", "empty.filter_description",
            "empty.trash_title", "empty.trash_description",
        ] {
            #expect(packageStrings.contains("\"\(key)\""), "missing package localization key \(key)")
        }
    }

    @Test func sdkAlbumAndFavoriteMigrationsHaveNoLegacyRuntimeFallback() throws {
        let driveSession = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSession.swift"
            ),
            encoding: .utf8
        )
        #expect(
            !driveSession.contains("func fetchAlbums("),
            "the superseded direct album catalog must not return beside the SDK catalog")
        #expect(
            !driveSession.contains("func setFavorite("),
            "favorite writes must not retain a direct-HTTP fallback beside SDK updatePhotos")

        let bridge = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift"
            ),
            encoding: .utf8
        )
        #expect(
            bridge.contains("SDKFavoriteWriter(client: bridge.photosClient)"),
            "favorite writes must run inside the bridge shutdown admission lease")
        #expect(bridge.contains("SDKAlbumCatalogBackend("))
        #expect(
            bridge.contains("client: photosClient")
                && bridge.contains("admission: shutdownGate")
                && bridge.contains("sharedAlbumSnapshotCache: sharedAlbumSnapshotCache"),
            "the SDK album catalog must share account shutdown and snapshot owners")
        #expect(
            !bridge.contains("func albums()"),
            "the manual album-name decryption bridge was replaced, not layered over")

        let facade = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/ProtonClientFacade.swift"
            ),
            encoding: .utf8
        )
        #expect(facade.contains("HTTPAlbumWriteBackend("))
        #expect(!facade.contains("HTTPAlbumBackend("))
        #expect(
            facade.contains("didLeaveSharedAlbum: { album in")
                && facade.contains("await librarySources.revokeAdditionalSource(for: album)"),
            "confirmed access loss must reach the shared source coordinator on every platform"
        )
    }

    @Test func sdkAlbumContentMigrationStaysParkedUntilContractIsComplete() throws {
        let sdkManifest = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Vendor/sdk-swift/Package.swift"),
            encoding: .utf8
        )
        #expect(
            sdkManifest.contains("releases/download/0.25.0/CProtonDriveSDK.xcframework.zip"),
            "the vendored SDK release changed; re-evaluate the parked P3 contract before updating this pin"
        )

        let sdkTypes = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Vendor/sdk-swift/Sources/Plumbing/PublicTypes.swift"
            ),
            encoding: .utf8
        )
        let sdkNodeUID = try Self.body(
            of: sdkTypes,
            from: "public struct SDKNodeUid: Sendable",
            to: "public struct SDKRevisionUid: Sendable"
        )
        #expect(sdkNodeUID.contains("public let volumeID: String"))
        #expect(sdkNodeUID.contains("public let nodeID: String"))

        let albumItem = try Self.body(
            of: sdkTypes,
            from: "public struct AlbumItem: Sendable",
            to: "public struct SDKDeviceUid: Sendable"
        )
        #expect(albumItem.contains("public let nodeUid: SDKNodeUid"))
        #expect(albumItem.contains("public let captureTime: Double"))
        let albumItemContract = albumItem.lowercased()
        for missingField in ["mediatype", "phototag", "relatedphoto", "mainphoto", "errors"] {
            #expect(
                !albumItemContract.contains(missingField),
                "SDK AlbumItem gained \(missingField); re-evaluate the parked P3 migration before updating this guard"
            )
        }

        let photoNode = try Self.body(
            of: sdkTypes,
            from: "public struct PhotoNode: Sendable",
            to: "public struct FileContentDigests: Sendable"
        )
        #expect(photoNode.contains("public let mediaType: String"))
        #expect(photoNode.contains("public let errors: [ProtonDriveSDKDriveError]"))
        let photoNodeContract = photoNode.lowercased()
        for missingRelationship in ["phototag", "relatedphoto", "mainphoto"] {
            #expect(
                !photoNodeContract.contains(missingRelationship),
                "SDK PhotoNode gained \(missingRelationship); re-evaluate P3 without assuming per-item getNode hydration"
            )
        }

        let sdkClient = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Vendor/sdk-swift/Sources/Client/EncryptedMemoriesClient/EncryptedMemoriesClient.swift"
            ),
            encoding: .utf8
        )
        #expect(sdkClient.contains("public func enumerateAlbum("))
        #expect(sdkClient.contains("public func cancelEnumerateAlbum(cancellationToken: UUID)"))

        let domain = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotosCore/PhotoLibrary.swift"
            ),
            encoding: .utf8
        )
        #expect(
            domain.contains("case album(id: String, title: String)"),
            "PhotoFilter must gain lossless volumeID + nodeID only as part of the complete P3 migration")

        let bridge = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift"
            ),
            encoding: .utf8
        )
        #expect(
            !bridge.contains(".enumerateAlbum("),
            "do not add an SDK, hybrid, or fallback album-content path before the P3 contract and performance gates pass"
        )
        #expect(bridge.contains("driveSession.fetchAlbumPhotos(volumeID: root.volumeID, albumLinkID: id)"))

        let driveSession = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSession.swift"
            ),
            encoding: .utf8
        )
        #expect(driveSession.contains("func fetchAlbumPhotos(volumeID: String, albumLinkID: String)"))
        #expect(driveSession.contains("/albums/\\(albumLinkID)/children?Desc=1"))
    }

    @Test func motionSidebarFilterTracksProtonSdkPhotoTag() throws {
        let domain = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotosCore/PhotoLibrary.swift"), encoding: .utf8)
        #expect(
            domain.contains("case motionPhotos = 4"),
            "Motion must remain aligned with Proton's server-side motionPhoto tag")
        #expect(domain.contains("case .motionPhotos: L10n.string(\"tag.motion\")"))

        let sdk = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Vendor/sdk-swift/Sources/Generated/proton.drive.sdk.pb.swift"), encoding: .utf8)
        #expect(
            sdk.contains("case motionPhoto // = 4"),
            "the vendored SDK must expose Proton_Drive_Sdk_PhotoTag.motionPhoto")

        let bridge = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift"), encoding: .utf8)
        #expect(
            bridge.contains("fetchPhotosList(volumeID: root.volumeID, tag: tag.rawValue)"),
            "sidebar smart filters must query Proton by the server tag raw value")
    }

    @Test func sidebarFilterChangesUseInitialViewportPolicy() throws {
        // A sidebar route switch opens the route via a one-shot INITIAL-VIEWPORT POLICY owned by the Metal grid
        // host: restore the route's remembered scroll position, or open at newest on first visit. Avoiding a
        // separate immediate scroll correction keeps route changes race-free.
        let mainView = Self.repoRoot.appendingPathComponent("App/Views/MainView.swift")
        let mainText = try String(contentsOf: mainView, encoding: .utf8)
        #expect(mainText.contains("@State private var routeScrollGeneration"))
        #expect(mainText.contains("routeScrollGeneration += 1"))
        #expect(mainText.contains("routeScrollGeneration: routeScrollGeneration"))
        // Per-route scroll-position memory: capture on leave, restore on return, threaded to the grid.
        #expect(mainText.contains("routeScrollPositions"))
        #expect(mainText.contains("currentScrollAnchor"))
        #expect(mainText.contains("routeInitialScrollAnchor: routeInitialScrollAnchor"))
        // MainView must not scroll-correct routes itself: no direct scrollToLatest, no per-route special-casing.
        #expect(!mainText.contains("gridProxy.scrollToLatest?()"))
        #expect(!mainText.contains("if newValue =="))
        #expect(!mainText.contains("switch newValue"))

        // Increment generation before starting async `select(...)`, so data cannot arrive under an old route.
        // Check this ordering inside the route-change handler.
        let onChangeBody = try Self.body(
            of: mainText,
            from: ".onChange(of: selection)",
            to: ".onChange(of: timelineModel.wholeLibraryContentRevision)"
        )
        #expect(onChangeBody.contains("routeScrollPositions[oldValue]"))
        #expect(onChangeBody.contains("routeInitialScrollAnchor = routeScrollPositions[newValue]"))
        let genBump = onChangeBody.range(of: "routeScrollGeneration += 1")
        let asyncSelect = onChangeBody.range(of: "await timelineModel.select(newValue)")
        #expect(genBump != nil, "the route-change handler must bump the generation")
        #expect(asyncSelect != nil, "the route-change handler must load the new route")
        if let g = genBump, let s = asyncSelect {
            #expect(
                g.upperBound <= s.lowerBound,
                "the generation must be bumped BEFORE the async select(...) - gen-after-load reintroduces the token/generation race"
            )
        }

        let timelineView = Self.repoRoot.appendingPathComponent(
            "Packages/EncryptedMemoriesKit/Sources/TimelineFeature/TimelineView.swift")
        let timelineText = try String(contentsOf: timelineView, encoding: .utf8)
        #expect(timelineText.contains("private let routeScrollGeneration: Int"))
        #expect(timelineText.contains("routeScrollGeneration: Int = 0"))
        #expect(timelineText.contains("routeScrollGeneration: routeScrollGeneration"))
        #expect(timelineText.contains("routeInitialScrollAnchor: routeInitialScrollAnchor"))  // memory threaded through
        #expect(timelineText.contains("let showsMonthLabels = gridProfile.showsMonthLabels(level: level)"))
        #expect(timelineText.contains("TimelineMarkerRequest("))
        #expect(timelineText.contains("monthMarkerRevision == gridDataRevision"))
        #expect(timelineText.contains("TimelineDateScrubber(markers: monthMarkers)"))
        #expect(timelineText.contains("proxy?.scrollToFlatIndex?(marker.index)"))
        #expect(
            timelineText.contains("Task.detached(priority: .userInitiated)"),
            "month-marker derivation must stay off the main actor")

        let timelineViewModel = Self.repoRoot.appendingPathComponent(
            "Packages/EncryptedMemoriesKit/Sources/TimelineFeature/TimelineViewModel.swift")
        let timelineViewModelText = try String(contentsOf: timelineViewModel, encoding: .utf8)
        // Search and month-marker derivation are presentation work, but neither may synchronously scan the
        // full route from the main-actor view model.
        #expect(!timelineViewModelText.contains("TimelineSearch.filter("))
        #expect(!timelineViewModelText.contains("MetalGridProductionAdapter.dateMarkers("))
        #expect(timelineText.contains("MetalGridProductionAdapter.dateMarkers(items: items, granularity: .month)"))

        let productionView = Self.repoRoot.appendingPathComponent(
            "Packages/EncryptedMemoriesKit/Sources/TimelineFeature/MetalProductionGridView.swift")
        let productionText = try String(contentsOf: productionView, encoding: .utf8)
        #expect(productionText.contains("var routeScrollGeneration: Int = 0"))
        #expect(productionText.contains("appliedRouteScrollGeneration"))
        #expect(productionText.contains("proxy.scrollToFlatIndex"))
        #expect(productionText.contains("var initialViewportPlacement: TimelineInitialViewportPlacement = .automatic"))
        #expect(productionText.contains("case .newest:"))
        #expect(productionText.contains("case .oldest:"))
        // The route data-source switch installs the route's initial-viewport policy ALONGSIDE the new data,
        // gated on a pending route generation (else `.preserve` - incremental updates never re-place).
        #expect(productionText.contains("initialViewport: routeChangePending ? routeInitialViewport : .preserve"))
        // Direct route-scroll hooks must stay out of production.
        #expect(!productionText.contains("showNewestOnceForRouteChange"))

        // `makeNSView` couples "mark generation applied" to arming a REAL placement, gated on a generation
        // mismatch - so host recreation installs a real placement rather than swallowing it. These are
        // unconditional (a refactor that drops the coupling must fail the guard, not silently skip it).
        let makeBody = try Self.body(
            of: productionText, from: "func makeNSView(context: Context) -> NSView {", to: "func updateNSView")
        #expect(
            makeBody.contains("host.requestInitialViewport(routeInitialViewport)"),
            "makeNSView must arm a real placement when it marks the generation applied")
        #expect(
            makeBody.contains("if routeScrollGeneration != coord.appliedRouteScrollGeneration"),
            "makeNSView must gate the placement+mark on a generation mismatch (never unconditional)")

        // Neither the makeNSView nor the updateNSView body may scroll the grid directly on a route change - the
        // host owns placement. (The proxy wiring of scrollToLatest/currentScrollAnchor lives in `wireProxy`, out
        // of these bodies.)
        let updateBody = try Self.body(
            of: productionText, from: "func updateNSView(_ nsView: NSView, context: Context) {",
            to: "private var routeInitialViewport")
        for (name, body) in [("makeNSView", makeBody), ("updateNSView", updateBody)] {
            #expect(!body.contains("scrollToBottom("), "\(name) must not scroll the grid directly")
            #expect(!body.contains("scrollToLatest?()"), "\(name) must not scroll the grid directly")
        }

        let host = Self.repoRoot.appendingPathComponent(
            "Packages/EncryptedMemoriesKit/Sources/TimelineFeature/MetalGridScrollHost.swift")
        let hostText = try String(contentsOf: host, encoding: .utf8)
        let anchor = Self.repoRoot.appendingPathComponent(
            "Packages/EncryptedMemoriesKit/Sources/GridCore/GridScrollAnchor.swift")
        let anchorText = try String(contentsOf: anchor, encoding: .utf8)
        // The host owns the pending initial-viewport state + the policy type (incl. `.restore`), `setDataSource`
        // takes the policy, and it exposes the read-only scroll offset the shell remembers per route.
        #expect(hostText.contains("enum GridInitialViewport"))
        #expect(hostText.contains("case restore(GridScrollAnchor<PhotoUID>)"))
        #expect(anchorText.contains("struct GridScrollAnchor<ItemID"))  // layout-invariant generic item anchor
        #expect(!hostText.contains("struct GridScrollAnchor"))
        #expect(hostText.contains("pendingInitialViewport"))
        #expect(
            hostText.contains("func setDataSource(_ source: MetalGridDataSource, initialViewport: GridInitialViewport"))
        #expect(hostText.contains("func currentScrollAnchor()"))
        #expect(hostText.contains("func scrollToFlatIndex(_ index: Int)"))
        #expect(hostText.contains("coordinator.cellContentRect(forFlatIndex: index)"))
        #expect(hostText.contains("coordinator.cellContentRect(forUID: anchor.itemID)"))
        #expect(!hostText.contains("func showNewestOnceForRouteChange"))
        // Unrelated hit-test inset invariants (kept stable by this change).
        #expect(hostText.contains("if point.x < eventLeadingInset"))
        #expect(!hostText.contains("convert(point, from: superview)"))

        // `applyContentSize` consumes the pending policy only after geometry is valid.
        // It clears the policy only when the window and clip height are valid.
        let applyBody = try Self.body(
            of: hostText, from: "private func applyContentSize(_ size: CGSize) {",
            to: "private func placeForInitialViewport")
        #expect(applyBody.contains("pendingInitialViewport != .preserve"))
        #expect(applyBody.contains("placeForInitialViewport(pendingInitialViewport, clipHeight: clipH)"))
        #expect(applyBody.contains("window != nil"))
        #expect(applyBody.contains("clipH > 0"))
        let guardRange = applyBody.range(of: "guard width > 1, size.height > 0 else { return }")
        let clearRange = applyBody.range(of: "pendingInitialViewport = .preserve")
        #expect(guardRange != nil, "applyContentSize must early-return on invalid geometry before touching the policy")
        #expect(clearRange != nil, "applyContentSize must clear the policy after consuming it")
        if let g = guardRange, let c = clearRange {
            #expect(g.upperBound <= c.lowerBound, "the geometry guard must precede the policy clear (no early clear)")
        }

        // Route placement must not re-arm sticky pinning or call the sticky bottom API.
        let placeBody = try Self.body(
            of: hostText,
            from: "private func placeForInitialViewport(_ policy: GridInitialViewport, clipHeight: CGFloat) {",
            to: "func requestInitialViewport")
        #expect(placeBody.contains("stickToBottom = false"))
        #expect(placeBody.contains("scrollLockOrigin = nil"))
        #expect(placeBody.contains("lastMagnifyEventTime = 0"))
        #expect(!placeBody.contains("stickToBottom = true"))
        #expect(!placeBody.contains("scrollToBottom()"))
    }

    @Test func mobileGridReanchorsVisiblePhotoAcrossViewportRotation() throws {
        let host = Self.repoRoot.appendingPathComponent(
            "Packages/EncryptedMemoriesKit/Sources/TimelineUIKitFeature/UIKitTimelineGridHost.swift"
        )
        let text = try String(contentsOf: host, encoding: .utf8)
        let layout = try Self.body(
            of: text,
            from: "public override func layoutSubviews()",
            to: "public override func safeAreaInsetsDidChange()"
        )

        #expect(
            layout.contains("captureViewportResizePositionIfNeeded()"),
            "rotation must capture a logical photo position before rebuilding content geometry")
        #expect(layout.contains("refreshContentSize()"))
        #expect(
            layout.contains("restoreViewportResizePosition(resizePosition)"),
            "rotation must restore the logical photo only after the new width/content size resolves")
        let refresh = layout.range(of: "refreshContentSize()")
        let restore = layout.range(of: "restoreViewportResizePosition(resizePosition)")
        if let refresh, let restore {
            #expect(
                refresh.upperBound <= restore.lowerBound,
                "restoring before the new content size exists reintroduces the rotation jump")
        }

        let capture = try Self.body(
            of: text,
            from: "private func captureViewportResizePositionIfNeeded()",
            to: "private var viewportGeometryChangedSinceLastLayout"
        )
        #expect(
            capture.contains("lastLaidOutViewportSize"),
            "the old scroll offset must be interpreted with the old viewport geometry")
        #expect(
            capture.contains("itemUIDs[top.index]"),
            "the preserved position must be keyed by photo identity, never a raw offset")
        #expect(
            capture.contains("return .newest"),
            "a newest-pinned grid must remain pinned to the newest edge after rotation")
    }

    @Test func mobileTimelineUnderlapsTabBarButProtectsTheNewestRow() throws {
        let host = Self.repoRoot.appendingPathComponent(
            "Packages/EncryptedMemoriesKit/Sources/TimelineUIKitFeature/UIKitTimelineGridHost.swift"
        )
        let text = try String(contentsOf: host, encoding: .utf8)
        #expect(
            !text.contains("scheduleFirstContentReadyAfterViewportSettles"),
            "launch correctness must come from stable native geometry, not guessed queue-settlement turns")
        let insetBody = try Self.body(
            of: text,
            from: "private func applyContentInsets()",
            to: "var maxContentOffsetY: CGFloat {"
        )
        #expect(
            insetBody.contains("let bottom = safeAreaInsets.bottom"),
            "the newest row must retain native bottom-bar and home-indicator clearance")
        #expect(
            insetBody.contains("scrollView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)"),
            "the bottom clearance must be trailing scroll content, not a permanent surface reservation")

        let mobileTimeline = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileTimelineScreen.swift"),
            encoding: .utf8
        )
        #expect(
            mobileTimeline.contains(".ignoresSafeArea(.container, edges: [.top, .horizontal, .bottom])"),
            "the timeline surface must extend under Liquid Glass while its trailing inset protects the newest row")
    }

    @Test func mobileLibraryRefinementsOwnTheirViewportEdges() throws {
        let mobileTimeline = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("iOSApp/MobileTimelineScreen.swift"),
            encoding: .utf8
        )
        let host = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/TimelineUIKitFeature/UIKitTimelineGridHost.swift"
            ),
            encoding: .utf8
        )
        let projection = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/TimelineCore/TimelineSearchProjection.swift"
            ),
            encoding: .utf8
        )
        let updateRefinement = try Self.body(
            of: mobileTimeline,
            from: "private func updateRefinement(_ update:",
            to: "private var aspectRatioGridBinding"
        )

        #expect(
            mobileTimeline.contains("?.presentationItems ?? model.items"),
            "filter-only results must consume Core's stable top-leading projection")
        #expect(
            projection.contains("presentationItems = Array(projection.snapshot.items.reversed())"),
            "Core must reverse a filter result once instead of reallocating it on every SwiftUI update")
        #expect(
            mobileTimeline.contains("fillOrder: usesTopLeadingProjection ? .topLeading : .newestBottomTrailing"),
            "bounded results start top-leading while the full library remains bottom-trailing")
        #expect(mobileTimeline.contains("initialViewportPlacement: usesTopLeadingProjection ? .oldest : .automatic"))
        #expect(
            mobileTimeline.contains("scrollToTopSignal: refinementTopPlacementSignal"),
            "every settled filter change must explicitly place its first row below the navigation bar")
        #expect(mobileTimeline.contains("refinementTopPlacementSignal &+= 1"))
        #expect(
            !updateRefinement.contains("currentScrollAnchor"),
            "a bounded result must never restore a full-library anchor into sparse content")
        #expect(host.contains("public func scrollToTop(animated: Bool = false)"))
        #expect(
            host.contains("let target = -safeAreaInsets.top"),
            "sparse top-leading results must rest below native navigation chrome")
    }

    private enum GuardError: Error { case markerNotFound }

    /// The source slice from the first occurrence of `from` up to (excluding) the next occurrence of `to`.
    private static func body(of text: String, from: String, to: String) throws -> String {
        guard let start = text.range(of: from) else {
            Issue.record("Start marker not found: \(from)")
            throw GuardError.markerNotFound
        }
        guard let end = text[start.upperBound...].range(of: to) else {
            Issue.record("End marker not found: \(to)")
            throw GuardError.markerNotFound
        }
        return String(text[start.lowerBound..<end.lowerBound])
    }
}
