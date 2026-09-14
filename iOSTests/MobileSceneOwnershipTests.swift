import PhotosCore
import SwiftUI
import Testing
import UIKit

@testable import EncryptedMemoriesMobile

/// Account-versus-scene ownership contracts for several iPad windows.
@Suite(.serialized) @MainActor struct MobileSceneOwnershipTests {
    @Test func applicationManifestSupportsMultipleScenes() throws {
        let manifest = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any])
        #expect(manifest["UIApplicationSupportsMultipleScenes"] as? Bool == true)
        if UIDevice.current.userInterfaceIdiom == .pad {
            #expect(UIApplication.shared.supportsMultipleScenes)
        }
    }

    @Test func accountRuntimeIsOneProcessWideOwner() {
        #expect(MobileAccountRuntime.shared === MobileAccountRuntime.shared)
        #expect(MobileAccountRuntime.shared.sessionModel === MobileAccountRuntime.shared.sessionModel)
        #expect(MobileAccountRuntime.shared.libraryModel === MobileAccountRuntime.shared.libraryModel)
    }

    @Test func aggregateSceneActivityReachesTheSharedRuntimeOnlyOnChange() {
        // The test host already owns the process session model; only the library model is isolated here.
        let runtime = MobileAccountRuntime(
            sessionModel: MobileAccountRuntime.shared.sessionModel, libraryModel: MobileLibraryModel())
        #expect(runtime.appliedOpportunity == nil)

        runtime.noteScene("a", phase: .active)
        #expect(runtime.appliedOpportunity == .foregroundActive)
        #expect(LibraryRuntimeState.shared.snapshot().executionOpportunity == .foregroundActive)

        // A second window that opens and then goes to the background must not demote the active account.
        runtime.noteScene("b", phase: .inactive)
        runtime.noteScene("b", phase: .background)
        #expect(runtime.appliedOpportunity == .foregroundActive)
        #expect(runtime.sceneLedger.sceneCount == 2)

        runtime.noteScene("a", phase: .inactive)
        #expect(runtime.appliedOpportunity == .foregroundInactive)
        #expect(LibraryRuntimeState.shared.snapshot().executionOpportunity == .foregroundInactive)

        runtime.noteScene("a", phase: .background)
        #expect(runtime.appliedOpportunity == .backgroundPermitted)

        // Closing the background window while another window returns to the foreground keeps the account
        // in the foreground; only that scene leaves the ledger.
        runtime.noteScene("a", phase: .active)
        runtime.noteSceneDisconnected("b")
        #expect(runtime.appliedOpportunity == .foregroundActive)
        #expect(runtime.sceneLedger.sceneCount == 1)
        #expect(runtime.sceneLedger.phase(of: "b") == nil)

        // The test runtime never observes UIKit scenes; restore the process default for other suites.
        runtime.noteScene("a", phase: .active)
    }

    @Test func sceneContextResolvesItsOwnWindowAndPresenter() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let firstContext = MobileSceneContext()
        let secondContext = MobileSceneContext()
        let firstWindow = UIWindow(windowScene: scene)
        let secondWindow = UIWindow(windowScene: scene)
        firstWindow.rootViewController = UIHostingController(
            rootView: Color.clear.mobileSceneWindowAnchor(firstContext))
        secondWindow.rootViewController = UIHostingController(
            rootView: Color.clear.mobileSceneWindowAnchor(secondContext))
        firstWindow.makeKeyAndVisible()
        secondWindow.isHidden = false
        defer {
            firstWindow.isHidden = true
            secondWindow.isHidden = true
            firstWindow.rootViewController = nil
            secondWindow.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(300))

        #expect(firstContext.window === firstWindow)
        #expect(secondContext.window === secondWindow)
        #expect(firstContext.topmostPresenter === firstWindow.rootViewController)
        #expect(secondContext.topmostPresenter === secondWindow.rootViewController)
        #expect(firstContext.topSafeAreaInset == firstWindow.safeAreaInsets.top)
        #expect(MobileSceneContext().window == nil)
        #expect(MobileSceneContext().topmostPresenter == nil)
    }

    @Test func settingsPresentationBelongsToTheScene() {
        let first = MobileSceneContext()
        let second = MobileSceneContext()
        first.settingsPresented = true
        #expect(first.settingsPresented)
        #expect(!second.settingsPresented)
    }

    /// Opens a real second window scene of the production app in the iPad simulator, verifies that it attaches
    /// to the one account runtime, then closes it and verifies that the account survives the closed window.
    @Test func secondWindowSceneAttachesToAndDetachesFromTheSharedAccount() async throws {
        guard UIApplication.shared.supportsMultipleScenes else {
            return
        }
        let runtime = MobileAccountRuntime.shared
        let sessionModel = runtime.sessionModel
        let libraryModel = runtime.libraryModel
        let existing = Set(UIApplication.shared.connectedScenes.map(\.session.persistentIdentifier))
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(role: .windowApplication)) {
            error in
            Issue.record("second scene activation failed: \(error)")
        }

        var second: UIWindowScene?
        for _ in 0..<50 where second == nil {
            try await Task.sleep(for: .milliseconds(200))
            second =
                UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { !existing.contains($0.session.persistentIdentifier) }
        }
        let secondScene = try #require(second, "the iPad simulator must connect a second window scene")
        let secondID = secondScene.session.persistentIdentifier
        defer { UIApplication.shared.requestSceneSessionDestruction(secondScene.session, options: nil) }
        try await Task.sleep(for: .seconds(2))

        #expect(runtime.isStarted)
        #expect(runtime.sceneLedger.phase(of: secondID) != nil, "the new scene must report into the account ledger")
        #expect(runtime.sceneLedger.sceneCount >= 2)
        #expect(runtime.appliedOpportunity == .foregroundActive)
        #expect(MobileAccountRuntime.shared.sessionModel === sessionModel)
        #expect(MobileAccountRuntime.shared.libraryModel === libraryModel)
        let secondWindow = try #require(secondScene.windows.first)
        #expect(secondWindow.rootViewController != nil, "the second window must host the production root")
        let firstScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { existing.contains($0.session.persistentIdentifier) })
        #expect(firstScene.windows.first?.rootViewController != nil)
        #expect(firstScene.windows.first !== secondWindow)
        writeSnapshot(of: secondWindow, name: "second-window-scene")
        if let firstWindow = firstScene.windows.first {
            writeSnapshot(of: firstWindow, name: "first-window-scene")
        }

        UIApplication.shared.requestSceneSessionDestruction(secondScene.session, options: nil)
        for _ in 0..<50 where runtime.sceneLedger.phase(of: secondID) != nil {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(runtime.sceneLedger.phase(of: secondID) == nil, "a closed window leaves the ledger")
        #expect(runtime.isStarted, "closing a window must not stop the account runtime")
        #expect(MobileAccountRuntime.shared.libraryModel === libraryModel)
        // Bring the original window back to the foreground, as the user would by tapping it. The simulator does
        // not always re-activate it on its own, and later suites need an active application state.
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: firstScene.session)) {
            error in
            Issue.record("first scene re-activation failed: \(error)")
        }
        for _ in 0..<50 where firstScene.activationState != .foregroundActive {
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(firstScene.activationState == .foregroundActive)
        #expect(
            runtime.appliedOpportunity == .foregroundActive,
            "the remaining window drives the account: \(String(describing: runtime.appliedOpportunity))")
    }

    private func writeSnapshot(of window: UIWindow, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_UI_SNAPSHOT_DIR"] else {
            return
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: url.appendingPathComponent("\(name).png"))
    }
}
