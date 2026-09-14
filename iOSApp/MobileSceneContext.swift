import Observation
import SwiftUI
import UIKit

/// Per-window-scene UI context. It binds presentations and geometry reads to the window that initiated them.
///
/// The account runtime is shared by every window (`MobileAccountRuntime`); this object is the opposite: one
/// instance per scene root, carrying only what belongs to that window. Global key-window lookups through
/// `UIApplication.connectedScenes` would pick an arbitrary window once several are open.
@MainActor
@Observable
final class MobileSceneContext {
    /// Settings is a scene-level presentation: the toolbar button and the keyboard command both open it over
    /// whichever tab this window shows.
    var settingsPresented = false

    @ObservationIgnored private(set) weak var window: UIWindow?

    func attach(window: UIWindow?) {
        self.window = window
    }

    /// The view controller that presents UIKit-hosted system UI (for example the limited-library picker)
    /// inside this scene, above any sheet the scene already shows.
    var topmostPresenter: UIViewController? {
        guard var presenter = window?.rootViewController else { return nil }
        while let presented = presenter.presentedViewController { presenter = presented }
        return presenter
    }

    /// The scene's top safe-area inset once its window is attached; the historical iPhone default before.
    var topSafeAreaInset: CGFloat {
        window?.safeAreaInsets.top ?? 47
    }
}

/// Keyboard and menu commands act on the focused window scene. `MobileMainTabView` publishes this target
/// through `focusedSceneValue`; the app-level `Commands` read it back and stay disabled without a scene.
struct MobileSceneCommandTarget {
    let selectTab: @MainActor (MobileTab) -> Void
    let openSettings: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var mobileSceneCommands: MobileSceneCommandTarget?
}

extension View {
    /// Reports the hosting window of this view hierarchy to the scene context.
    func mobileSceneWindowAnchor(_ context: MobileSceneContext) -> some View {
        background {
            MobileSceneWindowAnchor(context: context)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct MobileSceneWindowAnchor: UIViewRepresentable {
    let context: MobileSceneContext

    func makeUIView(context representableContext: Context) -> AnchorView {
        let view = AnchorView()
        view.onWindowChange = { [weak context] window in context?.attach(window: window) }
        return view
    }

    func updateUIView(_ view: AnchorView, context representableContext: Context) {
        view.onWindowChange = { [weak context] window in context?.attach(window: window) }
        context.attach(window: view.window)
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: ()) {
        view.onWindowChange = nil
    }

    final class AnchorView: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }
}
