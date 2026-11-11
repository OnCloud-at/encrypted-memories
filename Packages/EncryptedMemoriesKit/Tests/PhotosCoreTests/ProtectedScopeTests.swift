import Foundation
import PhotosCore
import XCTest

@MainActor
final class ProtectedScopeTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "ProtectedScopeTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    private let app = ProtectedScope.app

    // MARK: - 1 Launch

    func testAppLockIsOffByDefault() {
        XCTAssertFalse(AppSettingsDefault.appLockEnabled)
        XCTAssertEqual(
            app.enablement,
            ProtectedScopeEnablement(
                key: AppSettingsKey.appLockEnabled, defaultValue: AppSettingsDefault.appLockEnabled))
        XCTAssertNil(app.parent)
        let gate = makeGate()
        XCTAssertFalse(gate.isEnabled(app))
        XCTAssertEqual(gate.state(of: app), .unlocked)
        XCTAssertNil(defaults.object(forKey: AppSettingsKey.appLockEnabled), "reading must not write the preference")
    }

    func testAnEnabledScopeStartsLockedAndADisabledOneStartsUnlocked() {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        XCTAssertEqual(makeGate().state(of: app), .locked)
        XCTAssertFalse(makeGate().admits(app))
        defaults.set(false, forKey: AppSettingsKey.appLockEnabled)
        XCTAssertEqual(makeGate().state(of: app), .unlocked)
    }

    // MARK: - 2 Background grace period

    func testTheAppPolicyUsesTheStandardValues() {
        XCTAssertEqual(AppSettingsDefault.appLockGracePeriodSeconds, 30)
        XCTAssertEqual(
            ProtectedScopeGracePeriod.appOptions,
            [.zero, .seconds(30), .seconds(60), .seconds(300), .seconds(900)])
        XCTAssertEqual(
            ProtectedScopeGracePeriod.appChoice,
            ProtectedScopeGracePeriod(
                key: AppSettingsKey.appLockGracePeriodSeconds, defaultValue: .seconds(30),
                options: ProtectedScopeGracePeriod.appOptions))
        XCTAssertEqual(app.policy, .standard)
        let standard = ProtectedScopePolicy.standard
        XCTAssertEqual(standard.backgroundGracePeriod, .appChoice)
        XCTAssertFalse(standard.relocksOnLeave)
    }

    func testABackgroundShorterThanTheGracePeriodKeepsTheScopeUnlocked() async {
        let gate = await unlockedAppGate()
        let start = ContinuousClock.now
        gate.appDidEnterBackground(at: start)
        gate.appWillEnterForeground(at: start + .seconds(30) - .milliseconds(1))
        XCTAssertEqual(gate.state(of: app), .unlocked)
        XCTAssertNil(defaults.object(forKey: AppSettingsKey.appLockGracePeriodSeconds))
    }

    func testABackgroundOfTheGracePeriodLocksTheScope() async {
        let gate = await unlockedAppGate()
        let start = ContinuousClock.now
        gate.appDidEnterBackground(at: start)
        gate.appWillEnterForeground(at: start + .seconds(30))
        XCTAssertEqual(gate.state(of: app), .locked)
    }

    func testEveryGracePeriodChoiceLocksExactlyAtItsBoundary() async {
        for option in ProtectedScopeGracePeriod.appOptions {
            let gate = await unlockedAppGate()
            XCTAssertTrue(gate.setGracePeriod(option, for: app), "\(option)")
            XCTAssertEqual(gate.gracePeriod(of: app), option)
            XCTAssertEqual(
                defaults.object(forKey: AppSettingsKey.appLockGracePeriodSeconds) as? Int,
                Int(option.components.seconds))
            let start = ContinuousClock.now
            if option > .zero {
                gate.appDidEnterBackground(at: start)
                gate.appWillEnterForeground(at: start + option - .milliseconds(1))
                XCTAssertEqual(gate.state(of: app), .unlocked, "just before \(option)")
            }
            gate.appDidEnterBackground(at: start + .seconds(1000))
            gate.appWillEnterForeground(at: start + .seconds(1000) + option)
            XCTAssertEqual(gate.state(of: app), .locked, "at \(option)")
        }
    }

    func testImmediatelyLocksOnEveryBackground() async {
        let gate = await unlockedAppGate()
        gate.setGracePeriod(.zero, for: app)
        let start = ContinuousClock.now
        gate.appDidEnterBackground(at: start)
        gate.appWillEnterForeground(at: start)
        XCTAssertEqual(gate.state(of: app), .locked)
    }

    func testChangingTheGracePeriodNeedsNoAuthenticationAndKeepsTheScopeOpen() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success])
        let gate = makeGate(authenticator)
        await gate.unlock(app, reason: "unlock")
        XCTAssertTrue(gate.setGracePeriod(.seconds(300), for: app))
        XCTAssertEqual(gate.state(of: app), .unlocked)
        XCTAssertEqual(authenticator.reasons, ["unlock"])
    }

    func testOnlyAnOfferedGracePeriodCanBeStored() {
        let gate = makeGate()
        XCTAssertFalse(gate.setGracePeriod(.seconds(45), for: app))
        XCTAssertNil(defaults.object(forKey: AppSettingsKey.appLockGracePeriodSeconds))
    }

    func testTheGracePeriodOfALockedScopeCannotBeChanged() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let gate = makeGate(ScriptedAuthenticator(results: [.success]))
        XCTAssertFalse(gate.setGracePeriod(.seconds(900), for: app))
        XCTAssertNil(defaults.object(forKey: AppSettingsKey.appLockGracePeriodSeconds))
        await gate.unlock(app, reason: "unlock")
        XCTAssertTrue(gate.setGracePeriod(.seconds(900), for: app))
        XCTAssertEqual(gate.gracePeriod(of: app), .seconds(900))
    }

    func testAStoredValueOutsideTheOptionsCountsAsTheDefault() {
        defaults.set(45, forKey: AppSettingsKey.appLockGracePeriodSeconds)
        XCTAssertEqual(makeGate().gracePeriod(of: app), .seconds(30))
        defaults.set("later", forKey: AppSettingsKey.appLockGracePeriodSeconds)
        XCTAssertEqual(makeGate().gracePeriod(of: app), .seconds(30))
        defaults.set(900, forKey: AppSettingsKey.appLockGracePeriodSeconds)
        XCTAssertEqual(makeGate().gracePeriod(of: app), .seconds(900))
    }

    func testTheGracePeriodCountsFromTheFirstBackgroundEvent() async {
        let gate = await unlockedAppGate()
        let start = ContinuousClock.now
        gate.appDidEnterBackground(at: start)
        gate.appDidEnterBackground(at: start + .seconds(29))
        gate.appWillEnterForeground(at: start + .seconds(30))
        XCTAssertEqual(gate.state(of: app), .locked)
    }

    func testAForegroundEventWithoutABackgroundChangesNothing() async {
        let gate = await unlockedAppGate()
        gate.appWillEnterForeground(at: ContinuousClock.now + .seconds(3600))
        XCTAssertEqual(gate.state(of: app), .unlocked)
    }

    func testABackgroundAfterAForegroundStartsANewGracePeriod() async {
        let gate = await unlockedAppGate()
        let start = ContinuousClock.now
        gate.appDidEnterBackground(at: start)
        gate.appWillEnterForeground(at: start + .seconds(25))
        gate.appDidEnterBackground(at: start + .seconds(40))
        gate.appWillEnterForeground(at: start + .seconds(65))
        XCTAssertEqual(gate.state(of: app), .unlocked)
    }

    func testTheBackgroundStartSurvivesAnUnlock() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let gate = makeGate(ScriptedAuthenticator(results: [.success]))
        let start = ContinuousClock.now
        gate.appDidEnterBackground(at: start)
        await gate.unlock(app, reason: "unlock")
        XCTAssertEqual(gate.state(of: app), .unlocked)
        gate.appWillEnterForeground(at: start + .seconds(30))
        XCTAssertEqual(gate.state(of: app), .locked)
    }

    // MARK: - 3 Authentication results

    func testASuccessfulAuthenticationUnlocks() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success])
        let gate = makeGate(authenticator)
        let state = await gate.unlock(app, reason: "Unlock")
        XCTAssertEqual(state, .unlocked)
        XCTAssertTrue(gate.admits(app))
        XCTAssertEqual(authenticator.reasons, ["Unlock"])
    }

    func testACancelledOrFailedAuthenticationKeepsTheLockAndDoesNotRetry() async {
        for result in [DeviceOwnerAuthResult.cancelled, .failed] {
            defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
            let authenticator = ScriptedAuthenticator(results: [result])
            let gate = makeGate(authenticator)
            let state = await gate.unlock(app, reason: "Unlock")
            XCTAssertEqual(state, .locked, "\(result)")
            XCTAssertEqual(gate.state(of: app), .locked, "\(result)")
            XCTAssertEqual(authenticator.reasons.count, 1, "\(result) must not start a second prompt")
        }
    }

    func testTheScopeShowsAuthenticatingWhileThePromptIsOpen() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success], holds: true)
        let gate = makeGate(authenticator)
        let unlock = Task { await gate.unlock(app, reason: "Unlock") }
        await waitForPrompt(authenticator)
        XCTAssertEqual(gate.state(of: app), .authenticating)
        XCTAssertFalse(gate.admits(app))
        authenticator.release()
        let state = await unlock.value
        XCTAssertEqual(state, .unlocked)
    }

    func testUnlockingAnUnlockedScopeDoesNotAsk() async {
        let authenticator = ScriptedAuthenticator(results: [])
        let gate = makeGate(authenticator)
        let state = await gate.unlock(app, reason: "Unlock")
        XCTAssertEqual(state, .unlocked)
        XCTAssertTrue(authenticator.reasons.isEmpty)
    }

    // MARK: - Automatic prompt (one for each foreground entry)

    func testAnAutomaticPromptRunsOnceAtLaunchAndNotAgainWhenTheWindowReactivates() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.cancelled])
        let gate = makeGate(authenticator)
        await gate.unlockAutomatically(app, reason: "launch")
        // The prompt's sheet closes and the system reactivates the window; the host asks again.
        let state = await gate.unlockAutomatically(app, reason: "reactivated")
        XCTAssertEqual(state, .locked)
        XCTAssertEqual(authenticator.reasons, ["launch"])
    }

    func testEachForegroundEntryAllowsOneAutomaticPrompt() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.cancelled, .cancelled])
        let gate = makeGate(authenticator)
        await gate.unlockAutomatically(app, reason: "launch")
        let start = ContinuousClock.now
        gate.appDidEnterBackground(at: start)
        gate.appWillEnterForeground(at: start + .seconds(1))
        await gate.unlockAutomatically(app, reason: "foreground")
        await gate.unlockAutomatically(app, reason: "reactivated")
        XCTAssertEqual(authenticator.reasons, ["launch", "foreground"])
    }

    func testTheUnlockButtonStillAsksAfterTheAutomaticPrompt() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.cancelled, .success])
        let gate = makeGate(authenticator)
        await gate.unlockAutomatically(app, reason: "launch")
        let state = await gate.unlock(app, reason: "button")
        XCTAssertEqual(state, .unlocked)
        XCTAssertEqual(authenticator.reasons, ["launch", "button"])
    }

    // MARK: - 4 One authentication at a time

    func testConcurrentUnlocksShareOneAuthentication() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success, .success], holds: true)
        let gate = makeGate(authenticator)
        let first = Task { await gate.unlock(app, reason: "first") }
        await waitForPrompt(authenticator)
        let second = Task { await gate.unlock(app, reason: "second") }
        await yieldToWaitingTasks()
        authenticator.release()
        let states = await [first.value, second.value]
        XCTAssertEqual(states, [.unlocked, .unlocked])
        XCTAssertEqual(authenticator.reasons, ["first"])
    }

    func testAnUnlockDuringASwitchChangeDoesNotOpenASecondPrompt() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success, .success], holds: true)
        let gate = makeGate(authenticator)
        let disabling = Task { await gate.setEnabled(false, for: app, reason: "disable") }
        await waitForPrompt(authenticator)
        XCTAssertEqual(gate.state(of: app), .locked, "a switch change never shows the scope as authenticating")
        let unlock = Task { await gate.unlock(app, reason: "unlock") }
        await yieldToWaitingTasks()
        authenticator.release()
        let disabled = await disabling.value
        let state = await unlock.value
        XCTAssertTrue(disabled)
        XCTAssertEqual(state, .unlocked)
        XCTAssertEqual(authenticator.reasons, ["disable"])
    }

    // MARK: - Late results

    func testASuccessAfterASystemLockDoesNotOpenTheScope() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success], holds: true, ignoresCancel: true)
        let gate = makeGate(authenticator)
        let unlock = Task { await gate.unlock(app, reason: "unlock") }
        await waitForPrompt(authenticator)
        gate.systemDidLock()
        XCTAssertEqual(authenticator.cancelCount, 1)
        authenticator.release()
        let state = await unlock.value
        XCTAssertEqual(state, .locked)
    }

    func testASuccessAfterTheAppLeftTheForegroundDoesNotOpenTheScope() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success], holds: true, ignoresCancel: true)
        let gate = makeGate(authenticator)
        let unlock = Task { await gate.unlock(app, reason: "unlock") }
        await waitForPrompt(authenticator)
        gate.appDidEnterBackground(at: .now)
        XCTAssertEqual(authenticator.cancelCount, 1)
        authenticator.release()
        let state = await unlock.value
        XCTAssertEqual(state, .locked)
    }

    func testASwitchChangeAfterASystemLockIsNotSaved() async {
        let authenticator = ScriptedAuthenticator(results: [.success], holds: true, ignoresCancel: true)
        let gate = makeGate(authenticator)
        let enabling = Task { await gate.setEnabled(true, for: app, reason: "enable") }
        await waitForPrompt(authenticator)
        gate.systemDidLock()
        authenticator.release()
        let changed = await enabling.value
        XCTAssertFalse(changed)
        XCTAssertFalse(gate.isEnabled(app))
        XCTAssertNil(defaults.object(forKey: AppSettingsKey.appLockEnabled))
    }

    func testNoCancelWithoutAnAuthenticationInProgress() {
        let authenticator = ScriptedAuthenticator(results: [])
        let gate = makeGate(authenticator)
        gate.systemDidLock()
        gate.appDidEnterBackground(at: .now)
        XCTAssertEqual(authenticator.cancelCount, 0)
    }

    // MARK: - 5 The switch needs a successful authentication

    func testTurningTheLockOnNeedsASuccessfulAuthentication() async {
        for result in [DeviceOwnerAuthResult.cancelled, .failed] {
            let authenticator = ScriptedAuthenticator(results: [result])
            let gate = makeGate(authenticator)
            let changed = await gate.setEnabled(true, for: app, reason: "enable")
            XCTAssertFalse(changed, "\(result)")
            XCTAssertFalse(gate.isEnabled(app), "\(result)")
            XCTAssertNil(defaults.object(forKey: AppSettingsKey.appLockEnabled), "\(result)")
        }
        let authenticator = ScriptedAuthenticator(results: [.success])
        let gate = makeGate(authenticator)
        let changed = await gate.setEnabled(true, for: app, reason: "enable")
        XCTAssertTrue(changed)
        XCTAssertTrue(gate.isEnabled(app))
        XCTAssertEqual(defaults.object(forKey: AppSettingsKey.appLockEnabled) as? Bool, true)
        XCTAssertEqual(gate.state(of: app), .unlocked, "the person just authenticated")
        XCTAssertEqual(authenticator.reasons, ["enable"])
    }

    func testTurningTheLockOffNeedsASuccessfulAuthentication() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success, .cancelled, .success])
        let gate = makeGate(authenticator)
        await gate.unlock(app, reason: "unlock")
        let cancelled = await gate.setEnabled(false, for: app, reason: "disable")
        XCTAssertFalse(cancelled)
        XCTAssertTrue(gate.isEnabled(app))
        XCTAssertEqual(defaults.object(forKey: AppSettingsKey.appLockEnabled) as? Bool, true)
        let changed = await gate.setEnabled(false, for: app, reason: "disable")
        XCTAssertTrue(changed)
        XCTAssertFalse(gate.isEnabled(app))
        XCTAssertEqual(defaults.object(forKey: AppSettingsKey.appLockEnabled) as? Bool, false)
        XCTAssertEqual(authenticator.reasons, ["unlock", "disable", "disable"])
    }

    func testSettingTheCurrentValueDoesNotAsk() async {
        let authenticator = ScriptedAuthenticator(results: [])
        let gate = makeGate(authenticator)
        let changed = await gate.setEnabled(false, for: app, reason: "disable")
        XCTAssertTrue(changed)
        XCTAssertTrue(authenticator.reasons.isEmpty)
        XCTAssertNil(defaults.object(forKey: AppSettingsKey.appLockEnabled))
    }

    func testAChildSwitchCannotChangeWhileItsParentIsLocked() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success, .success])
        let gate = makeGate(authenticator)
        let locked = await gate.setEnabled(false, for: Self.protectedArea, reason: "disable")
        XCTAssertFalse(locked)
        XCTAssertTrue(gate.isEnabled(Self.protectedArea))
        XCTAssertTrue(authenticator.reasons.isEmpty)
        await gate.unlock(app, reason: "app")
        let changed = await gate.setEnabled(false, for: Self.protectedArea, reason: "disable")
        XCTAssertTrue(changed)
        XCTAssertFalse(gate.isEnabled(Self.protectedArea))
        XCTAssertEqual(authenticator.reasons, ["app", "disable"])
    }

    // MARK: - 6 No device lock

    func testWithoutADeviceLockTheSwitchCannotBeTurnedOn() async {
        let authenticator = ScriptedAuthenticator(results: [.success], availability: .noDeviceLock)
        let gate = makeGate(authenticator)
        XCTAssertEqual(gate.availability, .noDeviceLock)
        let changed = await gate.setEnabled(true, for: app, reason: "enable")
        XCTAssertFalse(changed)
        XCTAssertFalse(gate.isEnabled(app))
        XCTAssertTrue(authenticator.reasons.isEmpty)
        XCTAssertNil(defaults.object(forKey: AppSettingsKey.appLockEnabled))
    }

    func testWithoutADeviceLockAtLaunchTheAppOpensAndTheChoiceIsKept() {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let gate = makeGate(ScriptedAuthenticator(results: [], availability: .noDeviceLock))
        XCTAssertFalse(gate.isEnabled(app))
        XCTAssertEqual(gate.state(of: app), .unlocked)
        XCTAssertEqual(
            defaults.object(forKey: AppSettingsKey.appLockEnabled) as? Bool, true,
            "a launch, also a background launch, never writes the choice")
    }

    func testARemovedDeviceLockSeenOnForegroundTurnsTheLockOff() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success])
        let gate = makeGate(authenticator)
        await gate.unlock(app, reason: "unlock")
        authenticator.currentAvailability = .noDeviceLock
        let start = ContinuousClock.now
        gate.appDidEnterBackground(at: start)
        gate.appWillEnterForeground(at: start + .seconds(60))
        XCTAssertEqual(gate.state(of: app), .unlocked)
        XCTAssertEqual(defaults.object(forKey: AppSettingsKey.appLockEnabled) as? Bool, false)
        authenticator.currentAvailability = .available(.faceID)
        gate.appDidEnterBackground(at: start + .seconds(70))
        gate.appWillEnterForeground(at: start + .seconds(80))
        XCTAssertFalse(gate.isEnabled(app), "a new passcode does not turn the lock on by itself")
        XCTAssertEqual(gate.state(of: app), .unlocked)
    }

    func testANoDeviceLockResultTurnsTheLockOff() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let gate = makeGate(ScriptedAuthenticator(results: [.noDeviceLock]))
        let state = await gate.unlock(app, reason: "unlock")
        XCTAssertEqual(state, .unlocked)
        XCTAssertEqual(gate.availability, .noDeviceLock)
        XCTAssertEqual(defaults.object(forKey: AppSettingsKey.appLockEnabled) as? Bool, false)
    }

    func testARestoredDeviceLockOnForegroundKeepsAnEnabledScopeLocked() {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [], availability: .noDeviceLock)
        let gate = makeGate(authenticator)
        XCTAssertEqual(gate.state(of: app), .unlocked)
        authenticator.currentAvailability = .available(.touchID)
        gate.appDidEnterBackground(at: .now)
        gate.appWillEnterForeground(at: .now)
        XCTAssertEqual(gate.availability, .available(.touchID))
        XCTAssertEqual(gate.state(of: app), .locked, "a lock that was never authenticated stays closed")
    }

    // MARK: - 7 System lock

    func testASystemLockRelocksAtOnce() async {
        let gate = await unlockedAppGate()
        gate.systemDidLock()
        XCTAssertEqual(gate.state(of: app), .locked)
    }

    // MARK: - 8 Several windows

    func testOneUnlockServesEveryWindow() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success])
        let gate = makeGate(authenticator)
        let windows = [gate.enter(app), gate.enter(app)]
        await gate.unlock(app, reason: "window one")
        let second = await gate.unlock(app, reason: "window two")
        XCTAssertEqual(second, .unlocked)
        XCTAssertEqual(authenticator.reasons, ["window one"])
        windows.forEach { $0.release() }
        XCTAssertEqual(gate.state(of: app), .unlocked, "the app scope does not relock on leave")
    }

    // MARK: - 9-11 A second scope with the same code

    /// A test-only switch that is on until a test turns it off.
    private static func testEnablement(_ name: String) -> ProtectedScopeEnablement {
        ProtectedScopeEnablement(key: "ProtectedScopeTests.\(name)", defaultValue: true)
    }

    /// Declared only here: a second protected area needs this declaration and no new lock logic.
    private static let protectedArea = ProtectedScope(
        id: ProtectedScopeID("test.protectedArea"), parent: .app, policy: .standardChild,
        enablement: testEnablement("protectedArea"))

    /// An area inside the test area: only a relock of the test area can close it while it has no window.
    private static let innerArea = ProtectedScope(
        id: ProtectedScopeID("test.innerArea"), parent: protectedArea, policy: .standardChild,
        enablement: testEnablement("innerArea"))

    func testAChildPolicyRelocksOnLeave() {
        let child = ProtectedScopePolicy.standardChild
        XCTAssertTrue(child.relocksOnLeave)
        XCTAssertEqual(child.backgroundGracePeriod, .appChoice, "every area follows the person's choice")
    }

    func testAnAppUnlockLeavesAChildLocked() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let gate = makeGate(ScriptedAuthenticator(results: [.success]))
        await gate.unlock(app, reason: "app")
        XCTAssertTrue(gate.admits(app))
        XCTAssertEqual(gate.state(of: Self.protectedArea), .locked)
        XCTAssertFalse(gate.admits(Self.protectedArea))
    }

    func testAChildScopeNeedsItsOwnAuthenticationAfterTheAppUnlock() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success, .success])
        let gate = makeGate(authenticator)
        XCTAssertEqual(gate.state(of: Self.protectedArea), .locked)
        await gate.unlock(app, reason: "app")
        XCTAssertEqual(gate.state(of: Self.protectedArea), .locked)
        let state = await gate.unlock(Self.protectedArea, reason: "area")
        XCTAssertEqual(state, .unlocked)
        XCTAssertEqual(authenticator.reasons, ["app", "area"])
    }

    func testReenteringAChildAsksAgain() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success, .success, .success])
        let gate = makeGate(authenticator)
        await gate.unlock(app, reason: "app")
        let first = gate.enter(Self.protectedArea)
        await gate.unlock(Self.protectedArea, reason: "area")
        XCTAssertEqual(gate.state(of: Self.protectedArea), .unlocked)
        first.release()
        let second = gate.enter(Self.protectedArea)
        XCTAssertEqual(gate.state(of: Self.protectedArea), .locked)
        let state = await gate.unlock(Self.protectedArea, reason: "area again")
        XCTAssertEqual(state, .unlocked)
        XCTAssertEqual(authenticator.reasons, ["app", "area", "area again"])
        XCTAssertTrue(gate.admits(app), "leaving the child keeps the app open")
        second.release()
    }

    func testAChildScopeNeedsItsOwnAuthenticationWhenTheAppLockIsOff() async {
        let gate = makeGate(ScriptedAuthenticator(results: [.success]))
        XCTAssertTrue(gate.admits(app))
        XCTAssertEqual(gate.state(of: Self.protectedArea), .locked)
        await gate.unlock(Self.protectedArea, reason: "area")
        XCTAssertEqual(gate.state(of: Self.protectedArea), .unlocked)
    }

    func testAChildScopeCannotOpenWhileItsParentIsLocked() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success])
        let gate = makeGate(authenticator)
        let state = await gate.unlock(Self.protectedArea, reason: "area")
        XCTAssertEqual(state, .locked)
        let automatic = await gate.unlockAutomatically(Self.protectedArea, reason: "area")
        XCTAssertEqual(automatic, .locked)
        XCTAssertTrue(authenticator.reasons.isEmpty)
    }

    func testARelockedParentRelocksItsChildForGood() async {
        let authenticator = ScriptedAuthenticator(results: [.success, .success, .success])
        let gate = makeGate(authenticator)
        let window = gate.enter(Self.protectedArea)
        await gate.unlock(Self.protectedArea, reason: "area")
        await gate.unlock(Self.innerArea, reason: "inner")
        XCTAssertTrue(gate.admits(Self.innerArea))
        window.release()
        XCTAssertEqual(gate.state(of: Self.innerArea), .locked)
        await gate.unlock(Self.protectedArea, reason: "area again")
        XCTAssertEqual(gate.state(of: Self.innerArea), .locked, "the child's earlier unlock must not come back")
    }

    func testTurningTheAppLockOffRelocksItsChild() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success, .success, .success])
        let gate = makeGate(authenticator)
        await gate.unlock(app, reason: "app")
        await gate.unlock(Self.protectedArea, reason: "area")
        let changed = await gate.setEnabled(false, for: app, reason: "disable")
        XCTAssertTrue(changed)
        XCTAssertTrue(gate.admits(app))
        XCTAssertEqual(gate.state(of: Self.protectedArea), .locked)
    }

    func testADroppedWindowPresenceReleasesItself() async {
        let gate = makeGate(ScriptedAuthenticator(results: [.success]))
        var kept: ProtectedScopePresence? = gate.enter(Self.protectedArea)
        await gate.unlock(Self.protectedArea, reason: "area")
        var dropped: ProtectedScopePresence? = gate.enter(Self.protectedArea)
        XCTAssertNotNil(dropped)
        dropped = nil
        await yieldToWaitingTasks()
        XCTAssertEqual(gate.state(of: Self.protectedArea), .unlocked, "the kept window still shows it")
        XCTAssertNotNil(kept)
        kept = nil
        await yieldToWaitingTasks()
        XCTAssertEqual(gate.state(of: Self.protectedArea), .locked)
    }

    func testAChildRelockDuringTheAppPromptDoesNotCancelTheAppUnlock() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let authenticator = ScriptedAuthenticator(results: [.success], holds: true, ignoresCancel: true)
        let gate = makeGate(authenticator)
        let window = gate.enter(Self.protectedArea)
        let unlock = Task { await gate.unlock(app, reason: "app") }
        await waitForPrompt(authenticator)
        window.release()
        authenticator.release()
        let state = await unlock.value
        XCTAssertEqual(state, .unlocked)
        XCTAssertEqual(authenticator.cancelCount, 0)
    }

    func testARelockAroundTheAreaDuringItsPromptCancelsItsUnlock() async {
        let inner = Self.innerArea
        let authenticator = ScriptedAuthenticator(
            results: [.success, .success, .success], holds: true, ignoresCancel: true)
        let gate = makeGate(authenticator)
        let outerWindow = gate.enter(Self.protectedArea)
        let outer = Task { await gate.unlock(Self.protectedArea, reason: "outer") }
        authenticator.release()
        _ = await outer.value
        authenticator.rearm()
        let innerUnlock = Task { await gate.unlock(inner, reason: "inner") }
        await waitForPrompt(authenticator)
        outerWindow.release()
        authenticator.release()
        _ = await innerUnlock.value
        let again = Task { await gate.unlock(Self.protectedArea, reason: "outer again") }
        authenticator.release()
        _ = await again.value
        XCTAssertTrue(gate.admits(Self.protectedArea))
        XCTAssertEqual(gate.state(of: inner), .locked, "a success after the outer area relocked must not count")
    }

    func testAChildRelocksWhenTheLastWindowLeavesIt() async {
        let gate = makeGate(ScriptedAuthenticator(results: [.success, .success]))
        let first = gate.enter(Self.protectedArea)
        let second = gate.enter(Self.protectedArea)
        await gate.unlock(Self.protectedArea, reason: "area")
        first.release()
        first.release()
        XCTAssertTrue(first.isReleased)
        XCTAssertEqual(gate.state(of: Self.protectedArea), .unlocked, "another window still shows it")
        second.release()
        XCTAssertEqual(gate.state(of: Self.protectedArea), .locked)
        let third = gate.enter(Self.protectedArea)
        await gate.unlock(Self.protectedArea, reason: "area again")
        let fourth = gate.enter(Self.protectedArea)
        fourth.release()
        XCTAssertEqual(
            gate.state(of: Self.protectedArea), .unlocked, "a released window must not count twice")
        third.release()
        XCTAssertEqual(gate.state(of: Self.protectedArea), .locked)
    }

    func testAChildFollowsTheSameGracePeriod() async {
        let gate = makeGate(ScriptedAuthenticator(results: [.success]))
        await gate.unlock(Self.protectedArea, reason: "area")
        let start = ContinuousClock.now
        gate.appDidEnterBackground(at: start)
        gate.appWillEnterForeground(at: start + .seconds(30) - .milliseconds(1))
        XCTAssertEqual(gate.state(of: Self.protectedArea), .unlocked)
        gate.appDidEnterBackground(at: start + .seconds(40))
        gate.appWillEnterForeground(at: start + .seconds(70))
        XCTAssertEqual(gate.state(of: Self.protectedArea), .locked)
    }

    // MARK: - Helpers

    private func makeGate(_ authenticator: ScriptedAuthenticator = ScriptedAuthenticator(results: [])) -> AccessGate {
        AccessGate(authenticator: authenticator, defaults: defaults)
    }

    /// A hung gate fails the test instead of blocking the run.
    private func waitForPrompt(
        _ authenticator: ScriptedAuthenticator, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let started = await authenticator.started.wait(limit: .seconds(20))
        XCTAssertTrue(started, "the gate never asked", file: file, line: line)
    }

    /// Main-actor tasks run in order, so the task created before these yields reaches its first suspension first.
    private func yieldToWaitingTasks() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func unlockedAppGate() async -> AccessGate {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let gate = makeGate(ScriptedAuthenticator(results: [.success]))
        let state = await gate.unlock(app, reason: "unlock")
        XCTAssertEqual(state, .unlocked)
        return gate
    }
}

/// Answers each authentication with the next scripted result. With `holds`, every answer waits for `release()` or
/// `cancel()`. With `ignoresCancel`, a cancel does not change the answer, like a result already on its way.
@MainActor
private final class ScriptedAuthenticator: DeviceOwnerAuthenticating {
    var currentAvailability: DeviceOwnerAuthAvailability
    private(set) var reasons: [String] = []
    private(set) var cancelCount = 0
    private(set) var started = AsyncTestSignal()
    private var results: [DeviceOwnerAuthResult]
    private let holds: Bool
    private let ignoresCancel: Bool
    private var cancelled = false
    private var released = AsyncTestSignal()

    init(
        results: [DeviceOwnerAuthResult], holds: Bool = false, ignoresCancel: Bool = false,
        availability: DeviceOwnerAuthAvailability = .available(.faceID)
    ) {
        self.results = results
        self.holds = holds
        self.ignoresCancel = ignoresCancel
        currentAvailability = availability
    }

    func availability() -> DeviceOwnerAuthAvailability { currentAvailability }

    func authenticate(reason: String) async -> DeviceOwnerAuthResult {
        reasons.append(reason)
        started.fire()
        if holds { await released.wait() }
        guard !results.isEmpty else {
            XCTFail("unexpected authentication: \(reason)")
            return .failed
        }
        let result = results.removeFirst()
        return cancelled && !ignoresCancel ? .cancelled : result
    }

    func cancel() {
        cancelCount += 1
        cancelled = true
        if !ignoresCancel { released.fire() }
    }

    func release() { released.fire() }

    /// Starts a new prompt cycle: the next prompt waits for a new `release()`.
    func rearm() {
        started = AsyncTestSignal()
        released = AsyncTestSignal()
    }
}
