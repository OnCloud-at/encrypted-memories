import PhotosCore
import PrivacyFeature
import UIKit
import os

/// Covers one scene's complete window, including presented viewers and sheets, before iOS captures a preview.
@MainActor
final class MobilePrivacyPreviewShield {
    private weak var window: UIWindow?
    private var preview: UIImageView?
    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "PrivacyPreview")

    func update(enabled: Bool, isSceneActive: Bool, window: UIWindow?) {
        if self.window !== window {
            remove()
            self.window = window
        }
        guard let window,
            PrivacyPreviewPolicy.shouldCover(
                enabled: enabled, isSceneActive: isSceneActive, isWindowVisible: true)
        else {
            remove()
            return
        }
        if let preview {
            window.bringSubviewToFront(preview)
            return
        }

        let image = blurredSnapshot(of: window)
        if image == nil {
            Self.logger.error("Could not render the privacy preview; obscuring the window without an image.")
        }
        let cover = UIImageView(image: image)
        cover.frame = window.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.contentMode = .scaleToFill
        cover.backgroundColor = .systemBackground
        cover.accessibilityElementsHidden = true
        window.addSubview(cover)
        preview = cover
    }

    private func blurredSnapshot(of window: UIWindow) -> UIImage? {
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(1, PrivacyPreviewImageRenderer.maximumDimension / max(bounds.width, bounds.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: bounds.width * scale, height: bounds.height * scale), format: format)
        var complete = false
        let snapshot = renderer.image { context in
            context.cgContext.scaleBy(x: scale, y: scale)
            complete = window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        guard complete, let source = snapshot.cgImage,
            let blurred = PrivacyPreviewImageRenderer.render(source)
        else { return nil }
        return UIImage(cgImage: blurred)
    }

    func remove() {
        preview?.removeFromSuperview()
        preview = nil
    }
}

/// Keeps scene shields alive while SwiftUI replaces the root during a full-screen presentation.
@MainActor
final class MobilePrivacyPreviewShieldCenter: NSObject {
    static let shared = MobilePrivacyPreviewShieldCenter()

    @MainActor private final class Entry {
        weak var window: UIWindow?
        let shield = MobilePrivacyPreviewShield()
        var deactivating = false

        init(window: UIWindow) { self.window = window }
    }

    private var entries: [Entry] = []
    private var lastEnabled = PrivacyPreviewPolicy.isEnabled()

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(sceneWillDeactivate), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sceneDidActivate), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sceneDidDisconnect), name: UIScene.didDisconnectNotification, object: nil)
        center.addObserver(
            self, selector: #selector(preferenceChanged), name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard)
    }

    func register(window: UIWindow) {
        entries.removeAll { $0.window == nil }
        if !entries.contains(where: { $0.window === window }) { entries.append(Entry(window: window)) }
        refresh(window: window, enabled: PrivacyPreviewPolicy.isEnabled())
    }

    func refreshAll(enabled: Bool) {
        let changed = enabled != lastEnabled
        lastEnabled = enabled
        entries.removeAll { $0.window == nil }
        for entry in entries {
            guard let window = entry.window else { continue }
            refresh(window: window, enabled: enabled)
        }
        if changed {
            let activeSessions = Set(
                UIApplication.shared.connectedScenes.filter { $0.activationState == .foregroundActive }
                    .map { $0.session.persistentIdentifier })
            for session in UIApplication.shared.openSessions
            where !activeSessions.contains(session.persistentIdentifier) {
                UIApplication.shared.requestSceneSessionRefresh(session)
            }
        }
    }

    private func refresh(window: UIWindow, enabled: Bool, isActive: Bool? = nil) {
        guard let entry = entries.first(where: { $0.window === window }) else { return }
        entry.shield.update(
            enabled: enabled,
            isSceneActive: isActive
                ?? (!entry.deactivating && window.windowScene?.activationState == .foregroundActive),
            window: window)
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        for entry in entries where entry.window?.windowScene === scene {
            entry.deactivating = true
            if let window = entry.window {
                refresh(window: window, enabled: PrivacyPreviewPolicy.isEnabled(), isActive: false)
            }
        }
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        for entry in entries where entry.window?.windowScene === scene {
            entry.deactivating = false
            if let window = entry.window {
                refresh(window: window, enabled: PrivacyPreviewPolicy.isEnabled(), isActive: true)
            }
        }
    }

    @objc private func sceneDidDisconnect(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        entries.removeAll { entry in
            guard let window = entry.window else { return true }
            guard window.windowScene === scene else { return false }
            entry.shield.remove()
            return true
        }
    }

    @objc nonisolated private func preferenceChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.refreshAll(enabled: PrivacyPreviewPolicy.isEnabled())
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
