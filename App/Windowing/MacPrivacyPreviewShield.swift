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

        init(window: NSWindow) { self.window = window }
    }

    private weak var libraryWindow: NSWindow?
    private var entries: [Entry] = []
    private var enabled = false
    private var observesApplication = false
    private var applicationDeactivating = false

    func attach(to window: NSWindow, enabled: Bool) {
        libraryWindow = window
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
        }
        refresh()
    }

    @objc private func applicationWillResignActive(_ notification: Notification) {
        applicationDeactivating = true
        for window in NSApp.windows { setCovered(enabled, on: window) }
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        applicationDeactivating = false
        refresh()
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) { refresh() }

    @objc private func windowWillMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        setCovered(enabled, on: window)
        if enabled {
            window.contentView?.layoutSubtreeIfNeeded()
            window.display()
            CATransaction.flush()
        }
    }

    private func refresh() {
        entries.removeAll { $0.window == nil }
        guard libraryWindow != nil else { return }
        for window in NSApp.windows {
            setCovered(
                PrivacyPreviewPolicy.shouldCover(
                    enabled: enabled,
                    isSceneActive: NSApp.isActive && !applicationDeactivating,
                    isWindowVisible: window.occlusionState.contains(.visible) && !window.isMiniaturized),
                on: window)
        }
    }

    private func setCovered(_ covered: Bool, on window: NSWindow) {
        let entry: Entry
        if let existing = entries.first(where: { $0.window === window }) {
            entry = existing
        } else {
            entry = Entry(window: window)
            entries.append(entry)
        }
        guard covered, let content = window.contentView else {
            entry.blur?.removeFromSuperview()
            entry.blur = nil
            return
        }
        if let blur = entry.blur {
            if blur.superview !== content {
                blur.removeFromSuperview()
                content.addSubview(blur, positioned: .above, relativeTo: nil)
            }
            return
        }

        let effect = NSVisualEffectView(frame: content.bounds)
        effect.material = .fullScreenUI
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        let tint = NSView(frame: effect.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.7).cgColor
        effect.addSubview(tint)
        content.addSubview(effect, positioned: .above, relativeTo: nil)
        entry.blur = effect
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
