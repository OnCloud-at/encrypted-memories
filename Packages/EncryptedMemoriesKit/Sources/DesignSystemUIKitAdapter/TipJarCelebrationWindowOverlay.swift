#if canImport(UIKit) && !os(watchOS)
    import DesignSystemCore
    import Observation
    import SwiftUI
    import UIKit

    /// Hosts the shared celebration in a transparent window above every presentation in one iOS window scene.
    public struct TipJarCelebrationWindowOverlay: View {
        @State private var coordinator = TipJarCelebrationCoordinator.shared

        private let horizontalBias: CGFloat

        public init(horizontalBias: CGFloat = 0) {
            self.horizontalBias = horizontalBias
        }

        public var body: some View {
            TipJarCelebrationWindowAttachment(
                isCelebrating: coordinator.activeCelebration != nil,
                horizontalBias: horizontalBias
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @MainActor
    private struct TipJarCelebrationWindowAttachment: UIViewRepresentable {
        let isCelebrating: Bool
        let horizontalBias: CGFloat

        func makeCoordinator() -> TipJarCelebrationWindowPresenter {
            TipJarCelebrationWindowPresenter()
        }

        func makeUIView(context: Context) -> TipJarCelebrationWindowAttachmentView {
            let view = TipJarCelebrationWindowAttachmentView()
            view.windowSceneChanged = { [weak presenter = context.coordinator] scene in
                presenter?.attach(to: scene)
            }
            return view
        }

        func updateUIView(
            _ view: TipJarCelebrationWindowAttachmentView,
            context: Context
        ) {
            context.coordinator.attach(to: view.window?.windowScene)
            context.coordinator.setHorizontalBias(horizontalBias)
            context.coordinator.setCelebrating(isCelebrating)
        }

        static func dismantleUIView(
            _ view: TipJarCelebrationWindowAttachmentView,
            coordinator: TipJarCelebrationWindowPresenter
        ) {
            view.windowSceneChanged = nil
            coordinator.detach()
        }
    }

    @MainActor
    final class TipJarCelebrationWindowPresenter {
        private weak var windowScene: UIWindowScene?
        private var overlayWindow: TipJarCelebrationPassthroughWindow?
        private let contentModel = TipJarCelebrationWindowContentModel()
        private var isCelebrating = false

        func attach(to scene: UIWindowScene?) {
            if let windowScene, windowScene === scene { return }
            if windowScene == nil, scene == nil { return }

            overlayWindow?.isHidden = true
            overlayWindow = nil
            windowScene = scene
            refreshPresentation()
        }

        func setHorizontalBias(_ horizontalBias: CGFloat) {
            contentModel.horizontalBias = min(1, max(-1, horizontalBias))
        }

        func setCelebrating(_ isCelebrating: Bool) {
            guard self.isCelebrating != isCelebrating else { return }
            self.isCelebrating = isCelebrating
            refreshPresentation()
        }

        func detach() {
            overlayWindow?.isHidden = true
            overlayWindow = nil
            windowScene = nil
        }

        private func refreshPresentation() {
            switch TipJarCelebrationWindowPresentation.resolve(
                hasScene: windowScene != nil,
                isCelebrating: isCelebrating
            ) {
            case .detached:
                overlayWindow?.isHidden = true
                overlayWindow = nil
            case .hidden:
                overlayWindow?.isHidden = true
            case .visible:
                presentOverlay()
            }
        }

        private func presentOverlay() {
            guard let windowScene else { return }
            let overlayWindow = overlayWindow ?? makeOverlayWindow(in: windowScene)
            self.overlayWindow = overlayWindow
            overlayWindow.isHidden = false
        }

        private func makeOverlayWindow(in scene: UIWindowScene) -> TipJarCelebrationPassthroughWindow {
            let window = TipJarCelebrationPassthroughWindow(windowScene: scene)
            window.windowLevel = TipJarCelebrationWindowPolicy.windowLevel
            window.backgroundColor = .clear
            window.isOpaque = false
            window.isUserInteractionEnabled = TipJarCelebrationWindowPolicy.allowsUserInteraction
            window.accessibilityElementsHidden = true

            let hostingController = UIHostingController(
                rootView: TipJarCelebrationWindowContent(model: contentModel)
            )
            hostingController.view.backgroundColor = .clear
            window.rootViewController = hostingController
            return window
        }
    }

    @MainActor
    @Observable
    private final class TipJarCelebrationWindowContentModel {
        var horizontalBias: CGFloat = 0
    }

    private struct TipJarCelebrationWindowContent: View {
        @State var model: TipJarCelebrationWindowContentModel

        var body: some View {
            TipJarCelebrationOverlay(horizontalBias: model.horizontalBias)
        }
    }

    enum TipJarCelebrationWindowPresentation: Equatable {
        case detached
        case hidden
        case visible

        static func resolve(hasScene: Bool, isCelebrating: Bool) -> Self {
            guard hasScene else { return .detached }
            return isCelebrating ? .visible : .hidden
        }
    }

    enum TipJarCelebrationWindowPolicy {
        static let windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        static let allowsUserInteraction = false
    }

    @MainActor
    final class TipJarCelebrationPassthroughWindow: UIWindow {
        override var canBecomeKey: Bool { false }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            nil
        }
    }

    @MainActor
    private final class TipJarCelebrationWindowAttachmentView: UIView {
        var windowSceneChanged: ((UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowSceneChanged?(window?.windowScene)
        }
    }
#endif
