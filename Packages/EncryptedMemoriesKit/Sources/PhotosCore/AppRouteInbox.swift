import Foundation
import Observation

/// The account state that decides whether a route may open. Each platform maps its own session states onto it.
public enum AppRouteSessionState: Sendable, Equatable {
    /// The app restores a saved session at launch; a route waits for the result.
    case restoring
    /// No usable account: signed out, signing in, signing out or a failed sign-out. A route is dropped.
    case signedOut
    /// A signed-in account that the person can use now.
    case usable
}

/// The one rule that decides when a pending route opens, shared by every platform and every window. Otherwise the
/// route waits; the inbox drops it only when the account is signed out.
public enum AppRouteGate {
    /// - Parameters:
    ///   - libraryReady: the library of the usable account has loaded and is not being rebuilt.
    ///   - presentationBlocked: the window shows a viewer, sheet, cover, alert or confirmation dialog.
    public static func opens(
        session: AppRouteSessionState, libraryReady: Bool, presentationBlocked: Bool
    ) -> Bool {
        session == .usable && libraryReady && !presentationBlocked
    }
}

/// The window that may open a route.
public enum AppRouteTarget: Hashable, Sendable {
    /// The window that received the link.
    case window(UUID)
    /// The most recently active window. A Shortcuts action has no window of its own.
    case activeWindow
}

/// Holds the one route that an action or a link asked for until its window can show it, then hands it out once.
/// A newer route replaces an older one that has not opened yet. A route is never kept across a sign-out, so it
/// cannot open against another account.
@MainActor
@Observable
public final class AppRouteInbox {
    public struct Pending: Equatable, Sendable {
        public let route: AppRoute
        public let target: AppRouteTarget
    }

    public private(set) var pending: Pending?
    public private(set) var session: AppRouteSessionState = .restoring
    /// Counts every action and link that reached the app, also one that was dropped or ignored, so a platform can
    /// bring its window forward for each.
    public private(set) var arrivals = 0

    public init() {}

    /// Accepts a route from an action or a link. While signed out, the route is dropped.
    public func receive(_ route: AppRoute, for target: AppRouteTarget) {
        noteArrival()
        guard session != .signedOut else { return }
        pending = Pending(route: route, target: target)
    }

    /// Records a link that reached the app but names no route.
    public func noteArrival() {
        arrivals &+= 1
    }

    public func update(session: AppRouteSessionState) {
        self.session = session
        if session == .signedOut { pending = nil }
    }

    /// Drops a link route whose window closed before it could open.
    public func windowClosed(_ window: UUID) {
        if pending?.target == .window(window) { pending = nil }
    }

    /// Opens the pending route once in the asking window: returns it and clears it when the route targets this
    /// window and the gate opens it. Otherwise the route stays pending and the call returns nil.
    public func open(
        window: UUID, isActiveWindow: Bool, libraryReady: Bool, presentationBlocked: Bool
    ) -> AppRoute? {
        guard let pending else { return nil }
        switch pending.target {
        case .window(let target) where target != window: return nil
        case .activeWindow where !isActiveWindow: return nil
        default: break
        }
        guard AppRouteGate.opens(session: session, libraryReady: libraryReady, presentationBlocked: presentationBlocked)
        else { return nil }
        self.pending = nil
        return pending.route
    }
}
