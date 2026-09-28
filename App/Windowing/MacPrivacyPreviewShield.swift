import AppKit
import PhotosCore
import QuartzCore

/// Covers app windows before AppKit records inactive and minimized previews.
@MainActor
final class MacPrivacyPreviewShield: NSObject {
    static let shared = MacPrivacyPreviewShield()
    private final class Entry {
        weak var window: NSWindow?
        var blur: NSVisualEffectView?
        var miniaturizing = false
        var toolbarContentVisible: Bool?
        var isCovered = false

        init(window: NSWindow) { self.window = window }
    }

    private var entries: [Entry] = []
    private var enabled = false
    private var observesApplication = false
    private var applicationDeactivating = false

    func attach(to window: NSWindow, enabled: Bool) {
        _ = entry(for: window)
        self.enabled = enabled
        if !observesApplication {
            observesApplication = true
            let center = NotificationCenter.default
            center.addObserver(
                self, selector: #selector(applicationWillResignActive),
                name: NSApplication.willResignActiveNotification, object: NSApp)
            center.addObserver(
                self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification,
                object: NSApp)
            center.addObserver(
                self, selector: #selector(windowVisibilityChanged), name: NSWindow.didChangeOcclusionStateNotification,
                object: nil)
            center.addObserver(
                self, selector: #selector(windowWillMiniaturize), name: NSWindow.willMiniaturizeNotification,
                object: nil)
            center.addObserver(
                self, selector: #selector(windowVisibilityChanged), name: NSWindow.didDeminiaturizeNotification,
                object: nil)
            center.addObserver(
                self, selector: #selector(windowDidUpdate), name: NSWindow.didUpdateNotification, object: nil)
            center.addObserver(
                self, selector: #selector(preferenceChanged), name: UserDefaults.didChangeNotification,
                object: UserDefaults.standard)
        }
        refresh()
    }

    /// The launch cover supplies current intent; privacy must never restore a stale visibility snapshot.
    func setToolbarContentVisible(_ visible: Bool, on window: NSWindow) {
        let entry = entry(for: window)
        entry.toolbarContentVisible = visible
        updateToolbarVisibility(entry)
    }

    func update(window: NSWindow, enabled: Bool, isSceneActive: Bool, isWindowVisible: Bool) {
        setCovered(
            PrivacyPreviewPolicy.shouldCover(
                enabled: enabled, isSceneActive: isSceneActive, isWindowVisible: isWindowVisible), on: window)
    }

    @objc private func applicationWillResignActive(_ notification: Notification) {
        applicationDeactivating = true
        enabled = PrivacyPreviewPolicy.isEnabled()
        for window in NSApp.windows { setCovered(enabled, on: window) }
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        applicationDeactivating = false
        refresh()
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        if notification.name == NSWindow.didDeminiaturizeNotification,
            let window = notification.object as? NSWindow
        {
            entries.first(where: { $0.window === window })?.miniaturizing = false
        }
        refresh()
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let entry = entries.first(where: { $0.window === window })
        else { return }
        updateToolbarVisibility(entry)
    }

    @objc nonisolated private func preferenceChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.enabled = PrivacyPreviewPolicy.isEnabled()
            self?.refresh()
        }
    }

    @objc private func windowWillMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        enabled = PrivacyPreviewPolicy.isEnabled()
        entry(for: window).miniaturizing = true
        setCovered(enabled, on: window)
    }

    private func refresh() {
        entries.removeAll { $0.window == nil }
        for window in NSApp.windows {
            let miniaturizing = entries.first(where: { $0.window === window })?.miniaturizing ?? false
            update(
                window: window, enabled: enabled,
                isSceneActive: NSApp.isActive && !applicationDeactivating && !miniaturizing,
                isWindowVisible: window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }
    }

    private func setCovered(_ covered: Bool, on window: NSWindow) {
        let entry = entry(for: window)
        entry.isCovered = covered
        guard covered, let content = window.contentView else {
            entry.blur?.removeFromSuperview()
            entry.blur = nil
            updateToolbarVisibility(entry)
            return
        }
        if let blur = entry.blur {
            if blur.superview !== content {
                blur.removeFromSuperview()
                content.addSubview(blur, positioned: .above, relativeTo: nil)
            }
            updateToolbarVisibility(entry)
            return
        }

        let effect = NSVisualEffectView(frame: content.bounds)
        effect.material = .fullScreenUI
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        content.addSubview(effect, positioned: .above, relativeTo: nil)
        entry.blur = effect
        updateToolbarVisibility(entry)
        content.layoutSubtreeIfNeeded()
        window.display()
        CATransaction.flush()
    }

    private func updateToolbarVisibility(_ entry: Entry) {
        guard let contentVisible = entry.toolbarContentVisible, let toolbar = entry.window?.toolbar else { return }
        let visible = contentVisible && !entry.isCovered
        if toolbar.isVisible != visible { toolbar.isVisible = visible }
    }

    private func entry(for window: NSWindow) -> Entry {
        if let existing = entries.first(where: { $0.window === window }) { return existing }
        let newEntry = Entry(window: window)
        entries.append(newEntry)
        return newEntry
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
