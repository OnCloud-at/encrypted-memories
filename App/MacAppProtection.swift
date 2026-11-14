import AppKit
import Observation
import PhotosCore
import PrivacyFeature
import SwiftUI

/// Native window coverage. The shared gate owns authentication, grace periods and admission.
@MainActor
final class MacAppProtection: NSObject {
    static let shared = MacAppProtection(gate: AppProtection.gate)
    let gate: AccessGate
    private var roots: [WeakWindow] = []
    private var covers: [ObjectIdentifier: Cover] = [:]
    private var wasForeground = false
    private var refreshing = false
    private var observing = true

    @MainActor private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    @MainActor private final class Cover {
        let window: MacAppLockPanel
        let presentation: MacAppLockPresentation

        init(source: NSWindow, gate: AccessGate) {
            presentation = MacAppLockPresentation(gate: gate)
            window = MacAppLockPanel(
                contentRect: source.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.worksWhenModal = true
            window.animationBehavior = .none
            window.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: MacAppLockWindowContent(presentation: presentation))
        }

        func hide() {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }
    }

    init(gate: AccessGate) {
        self.gate = gate
        super.init()
        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didMoveNotification,
            NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didEndSheetNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
        ] {
            center.addObserver(self, selector: #selector(windowChanged), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(windowClosing), name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(
            self, selector: #selector(willUnhide), name: NSApplication.willUnhideNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sheetBeginning), name: NSWindow.willBeginSheetNotification, object: nil)
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(systemLocked), name: name, object: nil)
        }
        observeGate()
    }

    func register(window: NSWindow) {
        if !roots.contains(where: { $0.window === window }) { roots.append(WeakWindow(window)) }
        refresh()
    }

    func invalidate() {
        observing = false
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        covers.values.forEach { $0.hide() }
        covers = [:]
        roots = []
    }

    private func observeGate() {
        guard observing else { return }
        withObservationTracking {
            _ = gate.state(of: .app)
            _ = gate.isAuthenticating
            _ = gate.availability
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observing else { return }
                self.refresh()
                self.observeGate()
            }
        }
    }

    private func refresh() {
        guard !refreshing, observing else { return }
        refreshing = true
        defer { refreshing = false }
        roots.removeAll { $0.window == nil }
        let foreground =
            !NSApp.isHidden && roots.contains { $0.window?.isVisible == true && $0.window?.isMiniaturized == false }
        if foreground != wasForeground {
            wasForeground = foreground
            if foreground { gate.appWillEnterForeground(at: .now) } else { gate.appDidEnterBackground(at: .now) }
        }
        var targets: [ObjectIdentifier: NSWindow] = [:]
        func collect(_ window: NSWindow) {
            guard !(window is MacAppLockPanel), targets[ObjectIdentifier(window)] == nil else { return }
            targets[ObjectIdentifier(window)] = window
            for child in window.childWindows ?? [] { collect(child) }
            if let sheet = window.attachedSheet { collect(sheet) }
        }
        roots.compactMap(\.window).forEach(collect)
        if let modal = NSApp.modalWindow { collect(modal) }
        for key in Array(covers.keys) where targets[key] == nil {
            covers.removeValue(forKey: key)?.hide()
        }
        for (key, source) in targets {
            let show = !gate.admits(.app) && source.isVisible && !source.isMiniaturized && !NSApp.isHidden
            guard show else {
                covers[key]?.hide()
                continue
            }
            let cover = covers[key] ?? Cover(source: source, gate: gate)
            covers[key] = cover
            cover.presentation.phase = NSApp.isActive ? .active : .inactive
            cover.window.appearance = source.appearance
            cover.window.level = source.level
            if cover.window.frame != source.frame { cover.window.setFrame(source.frame, display: true) }
            if cover.window.parent !== source { source.addChildWindow(cover.window, ordered: .above) }
            if !cover.window.isVisible { cover.window.order(.above, relativeTo: source.windowNumber) }
            if source.isKeyWindow && !gate.isAuthenticating { cover.window.makeKey() }
        }
    }

    @objc private func windowChanged(_ note: Notification) { refresh() }

    @objc private func windowClosing(_ note: Notification) {
        guard let window = note.object as? NSWindow, !(window is MacAppLockPanel) else { return }
        roots.removeAll { $0.window === window }
        covers.removeValue(forKey: ObjectIdentifier(window))?.hide()
        refresh()
    }

    @objc private func willUnhide(_ note: Notification) {
        gate.appWillEnterForeground(at: .now)
    }

    @objc private func sheetBeginning(_ note: Notification) {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    @objc private func systemLocked(_ note: Notification) {
        gate.systemDidLock()
        refresh()
    }

    isolated deinit { invalidate() }
}

@MainActor @Observable
final class MacAppLockPresentation {
    let gate: AccessGate
    var phase: ScenePhase = .inactive
    init(gate: AccessGate) { self.gate = gate }
}

private struct MacAppLockWindowContent: View {
    let presentation: MacAppLockPresentation
    var body: some View {
        Color.clear.protectedScope(
            .app, gate: presentation.gate,
            unlockTitle: AppLockCopy.unlockTitle(for: presentation.gate.availability),
            accessibilityLabel: AppLockCopy.lockedLabel, reason: AppLockCopy.unlockReason
        )
        .environment(\.scenePhase, presentation.phase)
    }
}

final class MacAppLockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { parent?.performClose(sender) }
}

@MainActor
extension View {
    func macAppProtection() -> some View {
        protectedScope(
            .app, gate: MacAppProtection.shared.gate,
            unlockTitle: AppLockCopy.unlockTitle(for: MacAppProtection.shared.gate.availability),
            accessibilityLabel: AppLockCopy.lockedLabel, reason: AppLockCopy.unlockReason
        )
        .background(MacAppLockAttachment().frame(width: 0, height: 0))
    }
}

private struct MacAppLockAttachment: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        if let window = view.window { MacAppProtection.shared.register(window: window) }
    }
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MacAppProtection.shared.register(window: window) }
        }
    }
}
