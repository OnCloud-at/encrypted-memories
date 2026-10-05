import Foundation
import PhotosCore

#if DEBUG
    /// Starts the app signed in to the offline fixture account when a UI test passes `fixtureArgument`.
    /// Debug builds only: the App Store build contains neither this switch nor the fixture.
    @MainActor
    enum MobileUITestLaunch {
        nonisolated static let fixtureArgument = "-EncryptedMemoriesUITestFixture"
        private static var fixture: MobileSignedInFixture?

        /// With this argument the session model skips the saved account, so no real account service starts.
        nonisolated static var isRequested: Bool {
            ProcessInfo.processInfo.arguments.contains(fixtureArgument)
        }

        /// Waits for the session check at launch, so it cannot replace the fixture session afterward.
        static func installFixtureIfRequested(into runtime: MobileAccountRuntime) async {
            guard isRequested, fixture == nil else { return }
            UserDefaults.standard.removeObject(forKey: AppSettingsKey.mapAndPlacesEnabled)
            UserDefaults.standard.removeObject(forKey: AppSettingsKey.backupUsesMobileData)
            for await isChecking in runtime.sessionModel.$isCheckingSession.values where !isChecking {
                break
            }
            guard fixture == nil,
                let installed = try? await MobileSignedInFixture(runtime: runtime, includesVideo: true)
            else { return }
            fixture = installed
            installed.install()
        }
    }
#endif
