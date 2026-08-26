/// Shared presentation state for a Live Photo's two required viewer resources.
///
/// A Live Photo is ready only after the full-resolution still and the fully prefetched,
/// ready-to-play motion clip are both available. Platform views render this state; they do not
/// independently infer readiness from an image or player optional.
public enum LivePhotoCompositeReadiness: Equatable, Sendable {
    case notApplicable
    case loading
    case ready
    case failed

    public static func resolve(
        requiresMotion: Bool,
        isFullResolutionStillReady: Bool,
        didFullResolutionStillFail: Bool = false,
        motionState: LivePhotoMotionLoadState,
        isMotionRequested: Bool = true
    ) -> Self {
        guard requiresMotion else { return .notApplicable }
        guard isMotionRequested else { return .notApplicable }
        guard !didFullResolutionStillFail else { return .failed }
        guard isFullResolutionStillReady else { return .loading }
        switch motionState {
        case .idle, .loading:
            return .loading
        case .ready:
            return .ready
        case .failed:
            return .failed
        }
    }
}
