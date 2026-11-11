import Foundation
import Observation

/// Names one protected area of the app. The app itself is the root area.
public struct ProtectedScopeID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let app = ProtectedScopeID("app")
}

/// How long every window may stay in the background before an area locks again. The person picks one of
/// `options`; the choice is stored on this device only.
public struct ProtectedScopeGracePeriod: Equatable, Sendable {
    public let key: String
    public let defaultValue: Duration
    public let options: [Duration]

    public init(key: String, defaultValue: Duration, options: [Duration]) {
        self.key = key
        self.defaultValue = defaultValue
        self.options = options
    }

    /// The choices of the app lock: immediately, 30 seconds, 1 minute, 5 minutes and 15 minutes.
    public static let appOptions: [Duration] = [.zero, .seconds(30), .seconds(60), .seconds(300), .seconds(900)]
    /// The app lock's choice, shared by every area.
    public static let appChoice = ProtectedScopeGracePeriod(
        key: AppSettingsKey.appLockGracePeriodSeconds,
        defaultValue: .seconds(AppSettingsDefault.appLockGracePeriodSeconds), options: appOptions)

    /// A stored value that is not one of the options counts as the default.
    public func duration(in defaults: UserDefaults) -> Duration {
        guard let seconds = defaults.object(forKey: key) as? Int else { return defaultValue }
        let stored = Duration.seconds(seconds)
        return options.contains(stored) ? stored : defaultValue
    }
}

/// When a protected area locks again. Every area locks at launch, after its grace period with every window in the
/// background and when the screen sleeps or the user session switches out; only these values differ.
public struct ProtectedScopePolicy: Equatable, Sendable {
    /// The app.
    public static let standard = ProtectedScopePolicy()
    /// An area inside the app: also locks when its last window leaves it.
    public static let standardChild = ProtectedScopePolicy(relocksOnLeave: true)

    public var backgroundGracePeriod: ProtectedScopeGracePeriod
    /// Locks when the last window that shows the area leaves it.
    public var relocksOnLeave: Bool

    public init(backgroundGracePeriod: ProtectedScopeGracePeriod = .appChoice, relocksOnLeave: Bool = false) {
        self.backgroundGracePeriod = backgroundGracePeriod
        self.relocksOnLeave = relocksOnLeave
    }
}

/// Whether an area is protected: the person turns the protection on or off, and the choice is stored on this
/// device only. Without a device lock no choice is on, so the area opens without asking.
///
/// There is no always-on area. If one is added, it must fail closed without a device lock: its content stays
/// covered with the reason to set a passcode, and it never opens without asking.
public struct ProtectedScopeEnablement: Equatable, Sendable {
    public let key: String
    public let defaultValue: Bool

    public init(key: String, defaultValue: Bool) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

/// The declaration of one protected area. A new area needs only this value; the gate registers it on first use.
/// Unlocking an area never opens an area inside it: each area asks for its own authentication.
public struct ProtectedScope: Equatable, Sendable {
    public let id: ProtectedScopeID
    public let policy: ProtectedScopePolicy
    public let enablement: ProtectedScopeEnablement
    /// Holds at most one element. An array lets the declaration contain its parent's declaration.
    private let parents: [ProtectedScope]

    /// An area is never open while its parent is locked.
    public var parent: ProtectedScope? { parents.first }

    public init(
        id: ProtectedScopeID, parent: ProtectedScope?, policy: ProtectedScopePolicy,
        enablement: ProtectedScopeEnablement
    ) {
        self.id = id
        parents = parent.map { [$0] } ?? []
        self.policy = policy
        self.enablement = enablement
    }

    public static let app = ProtectedScope(
        id: .app, parent: nil, policy: .standard,
        enablement: ProtectedScopeEnablement(
            key: AppSettingsKey.appLockEnabled, defaultValue: AppSettingsDefault.appLockEnabled))
}

/// The method the system offers for the device owner's authentication.
public enum DeviceOwnerAuthMethod: Equatable, Sendable {
    case faceID, touchID, opticID, devicePasscode, accountPassword
}

public enum DeviceOwnerAuthAvailability: Equatable, Sendable {
    case available(DeviceOwnerAuthMethod)
    /// The device has no passcode or password, so nothing can be protected.
    case noDeviceLock
}

public enum DeviceOwnerAuthResult: Equatable, Sendable { case success, cancelled, failed, noDeviceLock }

/// The one authentication port of every protected area. The platform adapter uses the system's device owner
/// authentication; the app never sees biometric data.
@MainActor
public protocol DeviceOwnerAuthenticating: AnyObject {
    func availability() -> DeviceOwnerAuthAvailability
    func authenticate(reason: String) async -> DeviceOwnerAuthResult
    /// Ends the authentication in progress; its result then arrives as `cancelled`.
    func cancel()
}

public enum ProtectedScopeState: Equatable, Sendable { case unlocked, locked, authenticating }

/// One window showing a protected area. Release it when the window stops showing the area; a second release
/// does nothing, and a presence that is dropped without a release releases itself.
@MainActor
public final class ProtectedScopePresence {
    private weak var gate: AccessGate?
    private let scope: ProtectedScope
    public private(set) var isReleased = false

    fileprivate init(gate: AccessGate, scope: ProtectedScope) {
        self.gate = gate
        self.scope = scope
    }

    public func release() {
        guard !isReleased else { return }
        isReleased = true
        gate?.windowLeft(scope)
    }

    isolated deinit { release() }
}

/// Decides for every protected area whether it is open. One gate serves every window of the app session, so one
/// unlock opens an area in all windows. The gate covers only what the person sees: it never stops background work.
@MainActor
@Observable
public final class AccessGate {
    public private(set) var availability: DeviceOwnerAuthAvailability

    private let authenticator: any DeviceOwnerAuthenticating
    private let defaults: UserDefaults
    /// Registration happens inside reads, so these two never notify observers; `revision` does instead.
    @ObservationIgnored private var scopes: [ProtectedScopeID: ProtectedScope] = [:]
    @ObservationIgnored private var preferences: [ProtectedScopeID: Bool] = [:]
    private var revision = 0
    /// Areas opened by their own successful authentication since they last locked.
    private var unlocked: Set<ProtectedScopeID> = []
    private var authenticatingScope: ProtectedScopeID?
    @ObservationIgnored private var inFlight: Task<DeviceOwnerAuthResult, Never>?
    /// Grow when an area relocks (a relock also relocks every area inside it), and when the app leaves the foreground
    /// or the system locks. An authentication whose area relocked meanwhile does not open anything; a relock of an
    /// unrelated area does not affect it.
    @ObservationIgnored private var epochs: [ProtectedScopeID: Int] = [:]
    @ObservationIgnored private var sessionEpoch = 0
    @ObservationIgnored private var presence: [ProtectedScopeID: Int] = [:]
    @ObservationIgnored private var backgroundSince: ContinuousClock.Instant?
    /// Areas that already had their automatic prompt since the app last entered the foreground.
    @ObservationIgnored private var automaticPromptTaken: Set<ProtectedScopeID> = []

    /// Every enabled area starts locked.
    public init(authenticator: any DeviceOwnerAuthenticating, defaults: UserDefaults = .standard) {
        self.authenticator = authenticator
        self.defaults = defaults
        availability = authenticator.availability()
    }

    public func state(of scope: ProtectedScope) -> ProtectedScopeState {
        register(scope)
        if authenticatingScope == scope.id { return .authenticating }
        return isOpen(scope) ? .unlocked : .locked
    }

    /// The entry check for a route, a command or a view.
    public func admits(_ scope: ProtectedScope) -> Bool { state(of: scope) == .unlocked }

    /// Without a device lock nothing can be protected, so no area is enabled.
    public func isEnabled(_ scope: ProtectedScope) -> Bool {
        register(scope)
        _ = revision
        guard availability != .noDeviceLock else { return false }
        return preferences[scope.id] ?? false
    }

    /// Asks once; every caller waits for the authentication in progress. An area whose parent is locked stays locked.
    @discardableResult
    public func unlock(_ scope: ProtectedScope, reason: String) async -> ProtectedScopeState {
        register(scope)
        if let inFlight {
            _ = await inFlight.value
            return state(of: scope)
        }
        guard !isOpen(scope), parentIsOpen(scope) else { return state(of: scope) }
        authenticatingScope = scope.id
        _ = await authenticate(scope, reason: reason) { result in
            self.authenticatingScope = nil
            if result == .success { self.unlocked.insert(scope.id) }
        }
        return state(of: scope)
    }

    /// Asks at most once for each foreground entry and at launch, so a cancelled prompt does not return when the
    /// system reactivates the window after its sheet closes.
    @discardableResult
    public func unlockAutomatically(_ scope: ProtectedScope, reason: String) async -> ProtectedScopeState {
        register(scope)
        guard inFlight == nil, !isOpen(scope), parentIsOpen(scope),
            automaticPromptTaken.insert(scope.id).inserted
        else { return state(of: scope) }
        return await unlock(scope, reason: reason)
    }

    /// The time the app may stay in the background before the area locks.
    public func gracePeriod(of scope: ProtectedScope) -> Duration {
        register(scope)
        _ = revision
        return scope.policy.backgroundGracePeriod.duration(in: defaults)
    }

    /// Stores one of the offered choices of an open area. It needs no authentication: the person is inside it.
    @discardableResult
    public func setGracePeriod(_ duration: Duration, for scope: ProtectedScope) -> Bool {
        let gracePeriod = scope.policy.backgroundGracePeriod
        guard admits(scope), gracePeriod.options.contains(duration) else { return false }
        defaults.set(Int(duration.components.seconds), forKey: gracePeriod.key)
        revision += 1
        return true
    }

    /// Turns the protection of an area on or off after one successful authentication, while the area around it is
    /// open. Afterwards the area is open; every area inside it locks.
    public func setEnabled(_ enabled: Bool, for scope: ProtectedScope, reason: String) async -> Bool {
        register(scope)
        guard inFlight == nil, parentIsOpen(scope) else { return false }
        if preferences[scope.id] == enabled { return true }
        guard availability != .noDeviceLock else { return false }
        let result = await authenticate(scope, reason: reason) { result in
            guard result == .success else { return }
            self.preferences[scope.id] = enabled
            self.defaults.set(enabled, forKey: scope.enablement.key)
            self.revision += 1
            self.unlocked.insert(scope.id)
            self.relockChildren(of: scope.id)
        }
        return result == .success
    }

    /// A window shows the area until it releases the returned presence.
    public func enter(_ scope: ProtectedScope) -> ProtectedScopePresence {
        register(scope)
        presence[scope.id, default: 0] += 1
        return ProtectedScopePresence(gate: self, scope: scope)
    }

    /// The last window of the app left the foreground. The first call starts the grace period.
    public func appDidEnterBackground(at instant: ContinuousClock.Instant) {
        if backgroundSince == nil { backgroundSince = instant }
        automaticPromptTaken = []
        endAuthentication()
    }

    /// A window returns. Areas lock when the app stayed in the background for their grace period.
    public func appWillEnterForeground(at instant: ContinuousClock.Instant) {
        automaticPromptTaken = []
        refreshAvailability()
        guard let since = backgroundSince else { return }
        backgroundSince = nil
        let elapsed = since.duration(to: instant)
        for scope in scopes.values where elapsed >= scope.policy.backgroundGracePeriod.duration(in: defaults) {
            relock(scope.id)
        }
    }

    /// The screen slept or the user session switched out.
    public func systemDidLock() {
        endAuthentication()
        for scope in scopes.values { relock(scope.id) }
    }

    fileprivate func windowLeft(_ scope: ProtectedScope) {
        guard let count = presence[scope.id], count > 0 else { return }
        presence[scope.id] = count - 1
        if count == 1, scope.policy.relocksOnLeave { relock(scope.id) }
    }

    private func register(_ scope: ProtectedScope) {
        if let parent = scope.parent { register(parent) }
        guard scopes[scope.id] == nil else {
            assert(scopes[scope.id] == scope, "two declarations share the protected area \(scope.id.rawValue)")
            return
        }
        scopes[scope.id] = scope
        let key = scope.enablement.key
        preferences[scope.id] =
            defaults.object(forKey: key) == nil ? scope.enablement.defaultValue : defaults.bool(forKey: key)
    }

    private func isOpen(_ scope: ProtectedScope) -> Bool {
        parentIsOpen(scope) && (!isEnabled(scope) || unlocked.contains(scope.id))
    }

    private func parentIsOpen(_ scope: ProtectedScope) -> Bool {
        guard let parent = scope.parent else { return true }
        return isOpen(parent)
    }

    /// Locks the area and every area inside it, so an earlier child unlock cannot return with the parent.
    private func relock(_ scope: ProtectedScopeID) {
        epochs[scope, default: 0] += 1
        unlocked.remove(scope)
        relockChildren(of: scope)
    }

    private func relockChildren(of scope: ProtectedScopeID) {
        for child in scopes.values where child.parent?.id == scope { relock(child.id) }
    }

    private func refreshAvailability() {
        let current = authenticator.availability()
        if current == .noDeviceLock { deviceLockWasRemoved() } else { availability = current }
    }

    /// Without a device lock nothing can be protected, so every stored choice becomes off. Setting a passcode later
    /// does not turn the lock on by itself.
    private func deviceLockWasRemoved() {
        availability = .noDeviceLock
        for scope in scopes.values where preferences[scope.id] == true {
            preferences[scope.id] = false
            defaults.set(false, forKey: scope.enablement.key)
            revision += 1
        }
    }

    private func endAuthentication() {
        sessionEpoch += 1
        if inFlight != nil { authenticator.cancel() }
    }

    /// A relock of an area around this one also counts here, because it relocks this area too.
    private func epochMark(of scope: ProtectedScope) -> [Int] {
        [sessionEpoch, epochs[scope.id] ?? 0]
    }

    /// Applies the result before any waiting caller resumes, so a caller that shares the prompt sees its effect.
    /// A relock of the area during the prompt turns a late success into `cancelled`.
    private func authenticate(
        _ scope: ProtectedScope, reason: String, apply: @escaping @MainActor (DeviceOwnerAuthResult) -> Void
    ) async -> DeviceOwnerAuthResult {
        let authenticator = authenticator
        let startMark = epochMark(of: scope)
        let task = Task { () -> DeviceOwnerAuthResult in
            var result = await authenticator.authenticate(reason: reason)
            if result == .success, self.epochMark(of: scope) != startMark { result = .cancelled }
            if result == .noDeviceLock { self.deviceLockWasRemoved() }
            apply(result)
            self.inFlight = nil
            return result
        }
        inFlight = task
        return await task.value
    }
}
