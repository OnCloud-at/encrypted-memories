import PhotosCore

/// Shared user-facing projection of the platform-neutral Proton authentication progress state.
public enum ProtonAuthProgressPresentation {
    public static func status(for progress: ProtonForkAuthenticator.Progress) -> String {
        switch progress {
        case .requestingLink: L10n.string("auth.progress_requesting_link")
        case .waitingForBrowser: L10n.string("auth.progress_waiting_for_browser")
        case .finalizing: L10n.string("auth.progress_finalizing")
        }
    }
}
