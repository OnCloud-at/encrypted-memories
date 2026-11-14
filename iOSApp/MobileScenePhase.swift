import PhotosCore
import UIKit

/// The one mapping from UIScene lifecycle notifications and activation states to a scene phase.
enum MobileScenePhase {
    typealias Phase = LibrarySceneActivityLedger.ScenePhase

    /// The phase a scene has after each lifecycle notification. A disconnect has no phase.
    static let transitions: [(name: Notification.Name, phase: Phase)] = [
        (UIScene.didActivateNotification, .active),
        (UIScene.willDeactivateNotification, .inactive),
        (UIScene.willEnterForegroundNotification, .inactive),
        (UIScene.didEnterBackgroundNotification, .background),
    ]

    static func phase(after name: Notification.Name) -> Phase? {
        transitions.first { $0.name == name }?.phase
    }

    static func phase(of state: UIScene.ActivationState) -> Phase {
        switch state {
        case .foregroundActive: .active
        case .foregroundInactive: .inactive
        case .background, .unattached: .background
        @unknown default: .inactive
        }
    }
}
