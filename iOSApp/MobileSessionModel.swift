import MediaByteCache
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoPatchedGoImplementation
import ProtonDriveBackend
import SwiftUI
import UIKit

/// Owns the iOS/iPadOS shell around the shared `ProtonAuthController`; authentication behavior remains in Core.
@MainActor
final class MobileSessionModel: ObservableObject {
    static let signInPrompt = String(localized: "auth.sign_in_prompt")

    @Published private(set) var session: ProtonSession?
    @Published private(set) var isSigningIn = false
    @Published private(set) var isCheckingSession = false
    @Published private(set) var isSigningOut = false
    @Published private(set) var statusText = MobileSessionModel.signInPrompt
    @Published private(set) var errorText: String?

    let sessionStore = SessionKeychainStore()
    private let authController: ProtonAuthController
    private var startupPurgeSucceeded: Bool
    private var startupCleanupTask: Task<Void, Never>?
    private var protectedDataObserver: NSObjectProtocol?
    private let webAuthenticationSession = ManagedWebAuthenticationSession()
    private let webAuthenticationPresentationContext = ManagedWebAuthenticationPresentationContext {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        guard
            let window = windows.first(where: \.isKeyWindow)
                ?? windows.first(where: { !$0.isHidden })
        else {
            preconditionFailure("Web authentication requires an attached application window")
        }
        return window
    }

    init(startupPlaintextPurgeSucceeded: Bool? = nil) {
        injectDefaultCryptoImplementation()
        self.authController = ProtonAuthController(
            store: sessionStore,
            authenticator: ProtonForkAuthenticator(config: .externalDriveEncryptedMemories)
        )
        self.startupPurgeSucceeded = false
        self.startupCleanupTask = nil
        isCheckingSession = true
        statusText = String(localized: "auth.checking_session")
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.startupPurgeSucceeded {
                    self.beginStartupCleanup()
                } else {
                    self.bootstrapSessionIfNeeded()
                }
            }
        }
        beginStartupCleanup(plaintextPurgeSucceeded: startupPlaintextPurgeSucceeded)
    }

    private func beginStartupCleanup(plaintextPurgeSucceeded: Bool? = nil, signInAfterCleanup: Bool = false) {
        guard startupCleanupTask == nil else { return }
        apply(.checking)
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        let purgeClaim = BackupLocalDataPurge.claimSignOutPurge()
        startupPurgeSucceeded = false
        startupCleanupTask = Task { @MainActor [weak self] in
            let succeeded = await ProtonAuthLocalDataPurge.performStartupOffMain(
                claim: purgeClaim,
                plaintextPurgeSucceeded: plaintextPurgeSucceeded
            )
            guard let self else { return }
            self.startupPurgeSucceeded = succeeded
            self.startupCleanupTask = nil
            if succeeded, signInAfterCleanup {
                self.signIn()
            } else {
                self.bootstrapSessionIfNeeded()
            }
        }
    }

    deinit {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
    }

    func signIn() {
        isSigningOut = false
        guard startupCleanupTask == nil else { return }
        guard startupPurgeSucceeded, !BackupLocalDataPurge.isPurgePending() else {
            beginStartupCleanup(signInAfterCleanup: true)
            return
        }
        authController.signIn(
            openURL: { [weak self] url in
                Task { @MainActor [weak self] in
                    self?.startWebAuthenticationSession(url: url)
                }
            },
            onStateChange: { [weak self] state in
                self?.apply(state)
            }
        )
    }

    func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        AccountInfo.shared.clear()
        // Explicit user sign-out arms the local-data purge before tearing down the session, so the
        // post-teardown and next-launch checks wipe every account container. It stays unarmed for transient
        // session re-check; only here (see BackupLocalDataPurge).
        BackupLocalDataPurge.requestPurgeOnSignOut(
            persistentDomainName: Bundle.main.bundleIdentifier
        )
        apply(authController.signOut())
    }

    func completeSignOutPresentation() {
        isSigningOut = false
    }

    private func startWebAuthenticationSession(url: URL) {
        webAuthenticationSession.start(
            url: url,
            presentationContextProvider: webAuthenticationPresentationContext
        ) { [weak self] in
            guard let self, self.isSigningIn else { return }
            self.apply(self.authController.cancelSignIn())
        }
    }

    private func apply(_ state: ProtonAuthState) {
        if case .authenticating = state {
            // Keep the managed browser alive while the shared fork flow polls Proton.
        } else {
            webAuthenticationSession.cancel()
        }
        switch state {
        case .checking:
            session = nil
            isSigningIn = false
            isCheckingSession = true
            isSigningOut = false
            errorText = nil
            statusText = String(localized: "auth.checking_session")
        case .signedOut(let error):
            session = nil
            isSigningIn = false
            isCheckingSession = false
            errorText = error
            statusText = error == nil ? Self.signInPrompt : L10n.string("auth.sign_in_failed")
        case .authenticating(let progress):
            session = nil
            isSigningIn = true
            isCheckingSession = false
            isSigningOut = false
            errorText = nil
            statusText = ProtonAuthProgressPresentation.status(for: progress)
        case .signedIn(let session):
            self.session = session
            isSigningIn = false
            isCheckingSession = false
            isSigningOut = false
            errorText = nil
            statusText = String(localized: "auth.signed_in")
        }
    }

    /// A WhenUnlocked Keychain item is unavailable during an early launch before iOS releases
    /// protected data. Keep the session in the checking state and retry when the OS announces that
    /// the existing item can be read; this must never look like an account sign-out.
    private func bootstrapSessionIfNeeded() {
        guard startupCleanupTask == nil, session == nil, !isSigningIn, !isSigningOut else { return }
        guard UIApplication.shared.isProtectedDataAvailable else {
            apply(.checking)
            return
        }
        guard startupPurgeSucceeded else {
            apply(.signedOut(error: L10n.string("auth.sign_in_failed")))
            return
        }
        apply(authController.bootstrap())
    }
}
