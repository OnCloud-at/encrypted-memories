import UIKit

extension UIApplication {
    /// The window scene in which a test builds its windows: the foreground-active one, else the first by identifier.
    ///
    /// `connectedScenes` is an unordered set. A platform that cannot close a second scene, like the iPhone Duo
    /// simulator, keeps it for the rest of the run and restores it at later launches. A test that took an arbitrary
    /// scene then sometimes built its window in a background scene with other traits.
    @MainActor var foregroundWindowScene: UIWindowScene? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
            .sorted { $0.session.persistentIdentifier < $1.session.persistentIdentifier }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

/// A window that one hosted test adds to a scene. It fills the scene until the test sets another frame; the test
/// configures it and calls `makeKeyAndVisible()`. `close()` removes it from the scene again: a hidden window that stays
/// in the scene can remain its key window, and a later test then waits on an empty window.
@MainActor
final class HostedTestWindow {
    let window: UIWindow
    private let previousKeyWindow: UIWindow?

    init(scene: UIWindowScene) {
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
    }

    /// Hides the window, releases its root view controller and takes it out of the scene. The window that was key
    /// before becomes key again while it is still visible in this scene; no other window is made key.
    func close() {
        let scene = window.windowScene
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene = nil
        if let previous = previousKeyWindow, !previous.isHidden, previous.windowScene === scene { previous.makeKey() }
    }
}
