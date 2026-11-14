import AppKit
import PhotosCore
import PrivacyFeature
import SwiftUI

/// Native window coverage. The shared gate owns authentication, grace periods and admission.
@MainActor
final class MacAppProtection: NSObject {
    static let shared = MacAppProtection(gate: AppProtection.gate)
    let gate: AccessGate
    private let applicationIsActive: @MainActor () -> Bool
    private var roots: [WeakWindow] = []
    private var covers: [ObjectIdentifier: Cover] = [:]
    private var wasForeground = false
    private var refreshing = false
    private var observing = true
    private var gateObservation: ProtectedScopeObservation?
    private var hiding = false

    @MainActor private final class WeakWindow {
        weak var window: NSWindow?
        var presentation: ProtectedScopePresentation
        var suspended = false
        init(_ window: NSWindow, presentation: ProtectedScopePresentation) {
            self.window = window
            self.presentation = presentation
        }
    }

    @MainActor private final class Cover {
        let window: MacAppLockPanel
        let presentation: ProtectedScopePresentation

        init(source: NSWindow, presentation: ProtectedScopePresentation) {
            self.presentation = presentation
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

    init(gate: AccessGate, applicationIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive }) {
        self.gate = gate
        self.applicationIsActive = applicationIsActive
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
        center.addObserver(self, selector: #selector(willHide), name: NSApplication.willHideNotification, object: nil)
        center.addObserver(
            self, selector: #selector(willMiniaturize), name: NSWindow.willMiniaturizeNotification, object: nil)
        center.addObserver(
            self, selector: #selector(willUnhide), name: NSApplication.willUnhideNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sheetBeginning), name: NSWindow.willBeginSheetNotification, object: nil)
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(systemLocked), name: name, object: nil)
        }
        gateObservation = ProtectedScopeObservation(gate: gate) { [weak self] in self?.refresh() }
    }

    func register(window: NSWindow, presentation: ProtectedScopePresentation? = nil) {
        if let root = roots.first(where: { $0.window === window }) {
            if let presentation, root.presentation !== presentation {
                covers.removeValue(forKey: ObjectIdentifier(window))?.hide()
                root.presentation = presentation
            }
        } else {
            roots.append(WeakWindow(window, presentation: presentation ?? ProtectedScopePresentation(gate: gate)))
        }
        refresh()
    }

    /// Runs before a retained window orders in, so expired admission never reaches its first visible frame.
    func prepareToShow(window: NSWindow) {
        gate.appWillEnterForeground(at: .now)
        roots.first(where: { $0.window === window })?.suspended = false
        register(window: window)
    }

    /// Draws the snapshot before AppKit orders out or captures a minimized window.
    func prepareToHide(window: NSWindow) {
        roots.first(where: { $0.window === window })?.suspended = true
        refresh()
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func invalidate() {
        observing = false
        gateObservation?.invalidate()
        gateObservation = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        covers.values.forEach { $0.hide() }
        covers = [:]
        roots = []
    }

    private func refresh() {
        guard !refreshing, observing else { return }
        refreshing = true
        defer { refreshing = false }
        let liveRoots = roots.compactMap { root in
            root.window.map { (root: root, window: $0) }
        }
        roots = liveRoots.map(\.root)
        let foreground =
            !hiding && !NSApp.isHidden
            && liveRoots.contains {
                $0.window.isVisible && !$0.window.isMiniaturized && !$0.root.suspended
            }
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
        liveRoots.forEach { collect($0.window) }
        if let modal = NSApp.modalWindow { collect(modal) }
        for key in Array(covers.keys) where targets[key] == nil {
            covers.removeValue(forKey: key)?.hide()
        }
        for (key, source) in targets {
            let root = liveRoots.first { $0.window === source }?.root
            let foregroundWindow =
                !hiding && !NSApp.isHidden && source.isVisible
                && !source.isMiniaturized && !(root?.suspended ?? false)
            let active = applicationIsActive() && foregroundWindow
            let presentation = root?.presentation ?? covers[key]?.presentation ?? ProtectedScopePresentation(gate: gate)
            guard presentation.update(isActive: active) else {
                covers[key]?.hide()
                continue
            }
            let cover = covers[key] ?? Cover(source: source, presentation: presentation)
            covers[key] = cover
            cover.window.appearance = source.appearance
            cover.window.level = source.level
            if cover.window.frame != source.frame { cover.window.setFrame(source.frame, display: true) }
            if cover.window.parent !== source { source.addChildWindow(cover.window, ordered: .above) }
            // Keep the relationship while hidden: AppKit carries the covered child through ordering and snapshots.
            if source.isVisible && !source.isMiniaturized && !NSApp.isHidden && !cover.window.isVisible {
                cover.window.order(.above, relativeTo: source.windowNumber)
            }
            if active && source.isKeyWindow && !gate.isAuthenticating { cover.window.makeKey() }
        }
    }

    @objc private func windowChanged(_ note: Notification) {
        if note.name == NSApplication.didUnhideNotification { hiding = false }
        if note.name == NSWindow.didDeminiaturizeNotification || note.name == NSWindow.didBecomeKeyNotification,
            let window = note.object as? NSWindow, let root = roots.first(where: { $0.window === window })
        {
            gate.appWillEnterForeground(at: .now)
            root.suspended = false
        }
        refresh()
    }

    @objc private func windowClosing(_ note: Notification) {
        guard let window = note.object as? NSWindow, !(window is MacAppLockPanel) else { return }
        guard roots.contains(where: { $0.window === window }) else { return }
        prepareToHide(window: window)
    }

    @objc private func willUnhide(_ note: Notification) {
        let returning = roots.contains { root in
            guard let window = root.window else { return false }
            return window.isVisible && !window.isMiniaturized && !root.suspended
        }
        gate.appWillEnterForeground(at: .now, hasForegroundContent: returning)
        hiding = false
        refresh()
    }

    @objc private func willHide(_ note: Notification) {
        hiding = true
        refresh()
        for root in roots {
            root.window?.contentView?.needsLayout = true
            root.window?.contentView?.layoutSubtreeIfNeeded()
            root.window?.displayIfNeeded()
        }
    }

    @objc private func willMiniaturize(_ note: Notification) {
        if let window = note.object as? NSWindow, roots.contains(where: { $0.window === window }) {
            prepareToHide(window: window)
        }
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

private struct MacAppLockWindowContent: View {
    let presentation: ProtectedScopePresentation
    var body: some View {
        Color.clear.appProtection(presentation)
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
    func macAppProtection() -> some View { modifier(MacAppProtectionModifier()) }
}

private struct MacAppProtectionModifier: ViewModifier {
    @State private var presentation = ProtectedScopePresentation(gate: MacAppProtection.shared.gate)

    func body(content: Content) -> some View {
        content.appProtection(presentation)
            .background(MacAppLockAttachment(presentation: presentation).frame(width: 0, height: 0))
    }
}

private struct MacAppLockAttachment: NSViewRepresentable {
    let presentation: ProtectedScopePresentation
    func makeNSView(context: Context) -> Anchor { Anchor(presentation: presentation) }
    func updateNSView(_ view: Anchor, context: Context) {
        if let window = view.window { MacAppProtection.shared.register(window: window, presentation: presentation) }
    }
    final class Anchor: NSView {
        let presentation: ProtectedScopePresentation
        init(presentation: ProtectedScopePresentation) {
            self.presentation = presentation
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MacAppProtection.shared.register(window: window, presentation: presentation) }
        }
    }
}
