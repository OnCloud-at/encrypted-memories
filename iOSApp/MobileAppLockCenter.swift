import DesignSystemCore
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
    private let lifecycle: MobilePrivacyPreviewShieldCenter
    private var sceneObservation: UUID?
    private var gateObservation: ProtectedScopeObservation?

    @MainActor private final class Entry {
        weak var source: UIWindow?
        let scene: UIWindowScene
        let window: UIWindow
        let presentation: ProtectedScopePresentation
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

    init(gate: AccessGate, lifecycle: MobilePrivacyPreviewShieldCenter = .shared) {
        self.gate = gate
        self.lifecycle = lifecycle
        super.init()
        sceneObservation = lifecycle.observeScenes { [weak self] scene, event in
            self?.sceneChanged(scene, event: event)
        }
        gateObservation = ProtectedScopeObservation(gate: gate) { [weak self] in
            guard let self else { return }
            self.entries.forEach(self.refresh)
        }
    }

    func register(window: UIWindow) {
        guard let scene = window.windowScene else { return }
        if let entry = entries.first(where: { $0.scene === scene }) {
            entry.source = window
            refresh(entry)
            return
        }
        let entry = Entry(source: window, scene: scene, gate: gate)
        entries.append(entry)
        gate.appWillEnterForeground(at: .now, hasForegroundContent: lifecycle.phase(of: scene) != .background)
        refresh(entry)
    }

    func invalidate() {
        gateObservation?.invalidate()
        gateObservation = nil
        if let sceneObservation { lifecycle.removeSceneObserver(sceneObservation) }
        sceneObservation = nil
        for entry in entries {
            entry.window.isHidden = true
            entry.restoreAccessibility()
        }
        entries = []
    }

    private func refresh(_ entry: Entry) {
        let active = lifecycle.phase(of: entry.scene) == .active
        let show = entry.presentation.update(isActive: active)
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

    private func sceneChanged(_ scene: UIWindowScene, event: Notification.Name) {
        // Any app scene entering the foreground brings protected content back, also a new scene that has not
        // registered its window yet. Expire and reset the session before an active-phase automatic prompt runs.
        if event == UIScene.willEnterForegroundNotification || event == UIScene.didActivateNotification {
            gate.appWillEnterForeground(at: .now)
        }
        guard entries.contains(where: { $0.scene === scene }) else { return }
        if event == UIScene.didDisconnectNotification {
            for entry in entries where entry.scene === scene {
                entry.window.isHidden = true
                entry.restoreAccessibility()
            }
            entries.removeAll { $0.scene === scene }
        }
        entries.forEach(refresh)
        if event == UIScene.didEnterBackgroundNotification || event == UIScene.didDisconnectNotification,
            entries.allSatisfy({ lifecycle.phase(of: $0.scene) == .background })
        {
            gate.appDidEnterBackground(at: .now)
        }
    }

    isolated deinit { invalidate() }
}

private struct MobileAppLockWindowContent: View {
    let presentation: ProtectedScopePresentation

    var body: some View {
        GeometryReader { geometry in
            Color.clear.appProtection(presentation, contentBounds: geometry.mobileCenteredContentBounds)
        }
        .ignoresSafeArea()
        .environment(\.scenePhase, presentation.phase)
        .animation(nil, value: presentation.snapshot)
    }
}
