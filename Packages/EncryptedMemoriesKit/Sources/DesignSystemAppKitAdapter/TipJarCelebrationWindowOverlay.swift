import AppKit
import DesignSystemCore
import SwiftUI

/// Hosts the shared celebration in a transparent child window above the complete native macOS window.
public struct TipJarCelebrationWindowOverlay: View {
    @State private var coordinator = TipJarCelebrationCoordinator.shared

    public init() {}

    public var body: some View {
        TipJarCelebrationWindowAttachment(
            isCelebrating: coordinator.activeCelebration != nil
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
private struct TipJarCelebrationWindowAttachment: NSViewRepresentable {
    let isCelebrating: Bool

    func makeCoordinator() -> TipJarCelebrationWindowPresenter {
        TipJarCelebrationWindowPresenter()
    }

    func makeNSView(context: Context) -> TipJarCelebrationWindowAttachmentView {
        let view = TipJarCelebrationWindowAttachmentView()
        view.windowChanged = { [weak presenter = context.coordinator] window in
            presenter?.attach(to: window)
        }
        return view
    }

    func updateNSView(
        _ view: TipJarCelebrationWindowAttachmentView,
        context: Context
    ) {
        context.coordinator.attach(to: view.window)
        context.coordinator.setCelebrating(isCelebrating)
    }

    static func dismantleNSView(
        _ view: TipJarCelebrationWindowAttachmentView,
        coordinator: TipJarCelebrationWindowPresenter
    ) {
        view.windowChanged = nil
        coordinator.detach()
    }
}

@MainActor
final class TipJarCelebrationWindowPresenter {
    private weak var parentWindow: NSWindow?
    private(set) var overlayWindow: TipJarCelebrationPanel?
    private var observers: [NSObjectProtocol] = []
    private var isCelebrating = false

    func attach(to window: NSWindow?) {
        if let parentWindow, parentWindow === window {
            syncFrame()
            return
        }
        if parentWindow == nil, window == nil { return }

        detachFromParent()
        parentWindow = window
        guard let window else { return }
        observe(window)
        if isCelebrating {
            presentOverlay()
        }
    }

    func setCelebrating(_ isCelebrating: Bool) {
        guard self.isCelebrating != isCelebrating else {
            if isCelebrating { syncFrame() }
            return
        }
        self.isCelebrating = isCelebrating
        if isCelebrating {
            presentOverlay()
        } else {
            hideOverlay()
        }
    }

    func syncFrame() {
        guard let parentWindow, let overlayWindow else { return }
        overlayWindow.setFrame(parentWindow.frame, display: true)
    }

    func detach() {
        detachFromParent()
        overlayWindow = nil
    }

    private func presentOverlay() {
        guard let parentWindow else { return }
        let overlayWindow = overlayWindow ?? makeOverlayWindow()
        self.overlayWindow = overlayWindow
        syncFrame()

        if overlayWindow.parent !== parentWindow {
            overlayWindow.parent?.removeChildWindow(overlayWindow)
            parentWindow.addChildWindow(
                overlayWindow,
                ordered: TipJarCelebrationWindowPolicy.orderingMode
            )
        }
        if parentWindow.isVisible {
            overlayWindow.orderFront(nil)
        }
    }

    private func hideOverlay() {
        guard let overlayWindow else { return }
        overlayWindow.parent?.removeChildWindow(overlayWindow)
        overlayWindow.orderOut(nil)
    }

    private func detachFromParent() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        hideOverlay()
        parentWindow = nil
    }

    private func observe(_ window: NSWindow) {
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.syncFrame()
                    if self.isCelebrating {
                        self.presentOverlay()
                    }
                }
            }
        }
    }

    private func makeOverlayWindow() -> TipJarCelebrationPanel {
        let panel = TipJarCelebrationPanel(
            contentRect: .zero,
            styleMask: TipJarCelebrationWindowPolicy.styleMask,
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = TipJarCelebrationWindowPolicy.isOpaque
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = TipJarCelebrationWindowPolicy.ignoresMouseEvents
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]

        let hostingView = NSHostingView(rootView: TipJarCelebrationOverlay())
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        return panel
    }
}

enum TipJarCelebrationWindowPolicy {
    static let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    static let orderingMode: NSWindow.OrderingMode = .above
    static let ignoresMouseEvents = true
    static let isOpaque = false
}

@MainActor
final class TipJarCelebrationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class TipJarCelebrationWindowAttachmentView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}
