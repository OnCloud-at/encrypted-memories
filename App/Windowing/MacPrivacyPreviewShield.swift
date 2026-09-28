import AppKit
import PhotosCore

/// Covers the library window before AppKit records an inactive or occluded preview.
@MainActor
final class MacPrivacyPreviewShield: NSObject {
    private weak var window: NSWindow?
    private var blur: NSVisualEffectView?
    private var enabled = false
    private var observesApplication = false

    func attach(to window: NSWindow, enabled: Bool) {
        if self.window !== window {
            if let previous = self.window {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.didChangeOcclusionStateNotification, object: previous)
            }
            remove()
            self.window = window
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowOcclusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        self.enabled = enabled
        if !observesApplication {
            observesApplication = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(applicationWillResignActive),
                name: NSApplication.willResignActiveNotification, object: NSApp)
            NotificationCenter.default.addObserver(
                self, selector: #selector(applicationDidBecomeActive),
                name: NSApplication.didBecomeActiveNotification, object: NSApp)
        }
        refresh()
    }

    @objc private func applicationWillResignActive(_ notification: Notification) {
        setCovered(enabled)
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        refresh()
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        refresh()
    }

    private func refresh() {
        guard let window else { return }
        setCovered(
            PrivacyPreviewPolicy.shouldCover(
                enabled: enabled, isSceneActive: NSApp.isActive,
                isWindowVisible: window.occlusionState.contains(.visible)))
    }

    private func setCovered(_ covered: Bool) {
        guard let content = window?.contentView else { return }
        guard covered else {
            remove()
            return
        }
        if let blur {
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
        blur = effect
    }

    private func remove() {
        blur?.removeFromSuperview()
        blur = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
