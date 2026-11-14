import DesignSystemCore
import Observation
import PhotosCore
import PrivacyFeature
import SwiftUI
import UIKit

/// Owns one opaque lock window per scene, above sheets, alerts and the celebration window.
@MainActor
final class MobileAppLockCenter: NSObject {
    static let shared = MobileAppLockCenter(gate: MobileAppProtection.gate)

    private let gate: AccessGate
    private var entries: [Entry] = []
    private var observing = true

    @MainActor private final class Entry {
        weak var source: UIWindow?
        let scene: UIWindowScene
        let window: UIWindow
        let presentation: ProtectedScopePresentation
        var deactivating = false
        var background = false
        var hiddenAccessibility: [(UIWindow, Bool)] = []

        init(source: UIWindow, scene: UIWindowScene, gate: AccessGate) {
            self.source = source
            self.scene = scene
            presentation = ProtectedScopePresentation(gate: gate)
            window = UIWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 2)
            window.backgroundColor = .systemBackground
            window.isOpaque = true
            let host = UIHostingController(rootView: MobileAppLockWindowContent(presentation: presentation))
            host.view.backgroundColor = .systemBackground
            window.rootViewController = host
        }

        func restoreAccessibility() {
            for (window, wasHidden) in hiddenAccessibility { window.accessibilityElementsHidden = wasHidden }
            hiddenAccessibility = []
        }
    }

    init(gate: AccessGate) {
        self.gate = gate
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(willEnterForeground), name: UIScene.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(didActivate), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(
            self, selector: #selector(willDeactivate), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(
            self, selector: #selector(didEnterBackground), name: UIScene.didEnterBackgroundNotification, object: nil)
        center.addObserver(
            self, selector: #selector(didDisconnect), name: UIScene.didDisconnectNotification, object: nil)
        observeGate()
    }

    func register(window: UIWindow) {
        guard let scene = window.windowScene else { return }
        if let entry = entries.first(where: { $0.scene === scene }) {
            entry.source = window
            refresh(entry)
            return
        }
        let entry = Entry(source: window, scene: scene, gate: gate)
        entry.background = scene.activationState == .background
        entries.append(entry)
        if !entry.background { gate.appWillEnterForeground(at: .now) }
        refresh(entry)
    }

    func invalidate() {
        observing = false
        NotificationCenter.default.removeObserver(self)
        for entry in entries {
            entry.window.isHidden = true
            entry.restoreAccessibility()
        }
        entries = []
    }

    private func observeGate() {
        guard observing else { return }
        withObservationTracking {
            _ = gate.state(of: .app)
            _ = gate.isEnabled(.app)
            _ = gate.availability
            _ = gate.isAuthenticating
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observing else { return }
                self.entries.forEach(self.refresh)
                self.observeGate()
            }
        }
    }

    private func refresh(_ entry: Entry) {
        let active = !entry.deactivating && entry.scene.activationState == .foregroundActive
        let snapshot = !active && gate.isEnabled(.app)
        let show = snapshot || !gate.admits(.app)
        entry.presentation.snapshot = snapshot
        entry.presentation.phase = active ? .active : .inactive
        entry.window.frame = entry.scene.coordinateSpace.bounds
        if let source = entry.source {
            entry.window.overrideUserInterfaceStyle = source.traitCollection.userInterfaceStyle
        }
        if show {
            for window in entry.scene.windows where window !== entry.window {
                if !entry.hiddenAccessibility.contains(where: { $0.0 === window }) {
                    entry.hiddenAccessibility.append((window, window.accessibilityElementsHidden))
                }
                window.accessibilityElementsHidden = true
                window.endEditing(true)
            }
            UIView.performWithoutAnimation {
                if active && !gate.isAuthenticating {
                    entry.window.makeKeyAndVisible()
                } else {
                    entry.window.isHidden = false
                }
                entry.window.layoutIfNeeded()
            }
        } else {
            let wasKey = entry.window.isKeyWindow
            entry.window.isHidden = true
            entry.restoreAccessibility()
            if wasKey, active { entry.source?.makeKey() }
        }
    }

    @objc private func willEnterForeground(_ note: Notification) {
        guard let scene = note.object as? UIWindowScene else { return }
        // Reset the session before any hosting view can run its active-phase automatic task.
        gate.appWillEnterForeground(at: .now)
        for entry in entries where entry.scene === scene {
            entry.background = false
            entry.deactivating = true
            refresh(entry)
        }
    }

    @objc private func didActivate(_ note: Notification) {
        guard let scene = note.object as? UIWindowScene else { return }
        gate.appWillEnterForeground(at: .now)
        for entry in entries where entry.scene === scene {
            entry.background = false
            entry.deactivating = false
            refresh(entry)
        }
    }

    @objc private func willDeactivate(_ note: Notification) {
        guard let scene = note.object as? UIWindowScene else { return }
        for entry in entries where entry.scene === scene {
            entry.deactivating = true
            refresh(entry)
        }
    }

    @objc private func didEnterBackground(_ note: Notification) {
        guard let scene = note.object as? UIWindowScene else { return }
        for entry in entries where entry.scene === scene {
            entry.background = true
            entry.deactivating = true
            refresh(entry)
        }
        if !entries.isEmpty && entries.allSatisfy(\.background) { gate.appDidEnterBackground(at: .now) }
    }

    @objc private func didDisconnect(_ note: Notification) {
        guard let scene = note.object as? UIWindowScene else { return }
        for entry in entries where entry.scene === scene {
            entry.window.isHidden = true
            entry.restoreAccessibility()
        }
        entries.removeAll { $0.scene === scene }
        if entries.allSatisfy(\.background) { gate.appDidEnterBackground(at: .now) }
    }

    isolated deinit { invalidate() }
}

private struct MobileAppLockWindowContent: View {
    let presentation: ProtectedScopePresentation

    var body: some View {
        GeometryReader { geometry in
            if presentation.snapshot {
                ProtectedScopeCover(
                    unlockTitle: AppLockCopy.unlockTitle(for: presentation.gate.availability),
                    accessibilityLabel: AppLockCopy.lockedLabel, isAuthenticating: true,
                    contentBounds: geometry.mobileCenteredContentBounds
                ) {}
            } else {
                Color.clear.protectedScope(
                    .app, gate: presentation.gate,
                    unlockTitle: AppLockCopy.unlockTitle(for: presentation.gate.availability),
                    accessibilityLabel: AppLockCopy.lockedLabel, reason: AppLockCopy.unlockReason,
                    contentBounds: geometry.mobileCenteredContentBounds)
            }
        }
        .ignoresSafeArea()
        .environment(\.scenePhase, presentation.phase)
        .animation(nil, value: presentation.snapshot)
    }
}
