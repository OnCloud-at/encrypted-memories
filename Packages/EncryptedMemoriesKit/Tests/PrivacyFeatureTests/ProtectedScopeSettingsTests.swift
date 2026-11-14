import Foundation
import Observation
import PhotosCore
import PrivacyFeature
import SwiftUI
import XCTest

@MainActor
final class ProtectedScopeSettingsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "ProtectedScopeSettingsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testTheSwitchWaitsForAuthenticationBeforeItChanges() async {
        let owner = PendingDeviceOwner()
        let gate = AccessGate(authenticator: owner, defaults: defaults)
        let settings = ProtectedScopeSettings(gate: gate, scope: .app, reason: "Unlock the library")
        let binding = settings.enabled

        binding.wrappedValue = true
        XCTAssertFalse(binding.wrappedValue, "The switch must not optimistically enable protection")
        XCTAssertFalse(defaults.bool(forKey: AppSettingsKey.appLockEnabled))
        XCTAssertFalse(settings.canChange, "A second action must be disabled before the task starts")
        await fulfillment(of: [owner.requested], timeout: 5)
        XCTAssertEqual(owner.reasons, ["Unlock the library"])
        await answer(.success, owner: owner, settings: settings)

        XCTAssertTrue(binding.wrappedValue)
        XCTAssertTrue(defaults.bool(forKey: AppSettingsKey.appLockEnabled))
        XCTAssertTrue(settings.canChange)
    }

    func testCancellingEnableLeavesTheSwitchOff() async {
        await assertSwitchResult(initial: false, result: .cancelled, expected: false)
    }

    func testSettingsChangesUseTheLocalizedConfirmationReason() async {
        let owner = PendingDeviceOwner()
        let gate = AccessGate(authenticator: owner, defaults: defaults)
        let settings = ProtectedScopeSettings(gate: gate, scope: .app)
        settings.enabled.wrappedValue = true
        await fulfillment(of: [owner.requested], timeout: 5)
        XCTAssertEqual(owner.reasons.count, 1)
        XCTAssertTrue(
            ["Confirm this change.", "Bestätige diese Änderung."].contains(owner.reasons.first ?? ""),
            "The system prompt must describe confirming the settings change in the app's language")
        await answer(.cancelled, owner: owner, settings: settings)
        XCTAssertFalse(settings.enabled.wrappedValue)
    }

    func testFailingEnableLeavesTheSwitchOff() async {
        await assertSwitchResult(initial: false, result: .failed, expected: false)
    }

    func testCancellingDisableLeavesTheSwitchOn() async {
        await assertSwitchResult(initial: true, result: .cancelled, expected: true)
    }

    func testSuccessfulDisableTurnsTheSwitchOff() async {
        await assertSwitchResult(initial: true, result: .success, expected: false)
    }

    func testRepeatedWritesDoNotQueueAnotherSwitchChange() async {
        let owner = PendingDeviceOwner()
        let gate = AccessGate(authenticator: owner, defaults: defaults)
        let settings = ProtectedScopeSettings(gate: gate, scope: .app, reason: "Unlock")
        settings.enabled.wrappedValue = true
        settings.enabled.wrappedValue = false
        settings.enabled.wrappedValue = true
        await fulfillment(of: [owner.requested], timeout: 5)
        settings.enabled.wrappedValue = false
        await answer(.success, owner: owner, settings: settings)

        XCTAssertEqual(owner.reasons.count, 1)
        XCTAssertTrue(settings.enabled.wrappedValue)
        XCTAssertTrue(settings.canChange)
    }

    func testWithoutADeviceLockTheSwitchCannotChange() {
        let owner = PendingDeviceOwner(availability: .noDeviceLock)
        let gate = AccessGate(authenticator: owner, defaults: defaults)
        let settings = ProtectedScopeSettings(gate: gate, scope: .app, reason: "Unlock")
        XCTAssertFalse(settings.canChange)
        settings.enabled.wrappedValue = true
        XCTAssertFalse(settings.enabled.wrappedValue)
        XCTAssertFalse(settings.isChanging)
        XCTAssertTrue(owner.reasons.isEmpty)
    }

    func testANoDeviceLockAuthenticationResultTurnsTheSavedSwitchOff() async {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let owner = PendingDeviceOwner()
        let gate = AccessGate(authenticator: owner, defaults: defaults)
        let settings = ProtectedScopeSettings(gate: gate, scope: .app, reason: "Unlock")
        let binding = settings.enabled
        binding.wrappedValue = false
        XCTAssertTrue(binding.wrappedValue, "The stored choice stays on while authentication is pending")
        await fulfillment(of: [owner.requested], timeout: 5)
        await answer(.noDeviceLock, owner: owner, settings: settings)

        XCTAssertFalse(binding.wrappedValue)
        XCTAssertFalse(defaults.bool(forKey: AppSettingsKey.appLockEnabled))
        XCTAssertEqual(gate.availability, .noDeviceLock)
        XCTAssertFalse(settings.canChange)
        XCTAssertFalse(settings.isChanging)
        binding.wrappedValue = true
        XCTAssertFalse(binding.wrappedValue)
        XCTAssertFalse(settings.isChanging)
        XCTAssertEqual(owner.reasons.count, 1)
    }

    func testAuthenticationDisablesTheSettingsInEveryWindow() async {
        let owner = PendingDeviceOwner()
        let gate = AccessGate(authenticator: owner, defaults: defaults)
        let firstWindow = ProtectedScopeSettings(gate: gate, scope: .app, reason: "Unlock")
        let secondWindow = ProtectedScopeSettings(gate: gate, scope: .app, reason: "Unlock")
        let becameBusy = expectation(description: "The other window observed authentication")
        withObservationTracking {
            _ = secondWindow.canChange
        } onChange: {
            becameBusy.fulfill()
        }

        firstWindow.enabled.wrappedValue = true
        await fulfillment(of: [owner.requested, becameBusy], timeout: 5)
        XCTAssertFalse(secondWindow.canChange)
        secondWindow.gracePeriod.wrappedValue = .seconds(300)
        XCTAssertEqual(secondWindow.gracePeriod.wrappedValue, .seconds(30))
        await answer(.cancelled, owner: owner, settings: firstWindow)

        XCTAssertTrue(secondWindow.canChange)
        XCTAssertFalse(secondWindow.enabled.wrappedValue)
        XCTAssertEqual(owner.reasons.count, 1)
    }

    func testThePickerReadsAndWritesThroughTheGateWithoutAuthentication() {
        let owner = PendingDeviceOwner()
        let gate = AccessGate(authenticator: owner, defaults: defaults)
        let settings = ProtectedScopeSettings(gate: gate, scope: .app, reason: "Unlock")
        let binding = settings.gracePeriod
        XCTAssertEqual(binding.wrappedValue, .seconds(30))
        binding.wrappedValue = .seconds(300)
        XCTAssertEqual(gate.gracePeriod(of: .app), .seconds(300))
        XCTAssertEqual(defaults.integer(forKey: AppSettingsKey.appLockGracePeriodSeconds), 300)

        gate.setGracePeriod(.seconds(60), for: .app)
        XCTAssertEqual(binding.wrappedValue, .seconds(60), "The binding must read the gate, not a saved copy")
        XCTAssertTrue(owner.reasons.isEmpty)
    }

    func testALockedAreaCannotChangeItsPicker() {
        defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
        let owner = PendingDeviceOwner()
        let gate = AccessGate(authenticator: owner, defaults: defaults)
        let settings = ProtectedScopeSettings(gate: gate, scope: .app, reason: "Unlock")
        settings.gracePeriod.wrappedValue = .seconds(300)
        XCTAssertEqual(settings.gracePeriod.wrappedValue, .seconds(30))
        XCTAssertTrue(owner.reasons.isEmpty)
    }

    private func assertSwitchResult(initial: Bool, result: DeviceOwnerAuthResult, expected: Bool) async {
        defaults.set(initial, forKey: AppSettingsKey.appLockEnabled)
        let owner = PendingDeviceOwner()
        let gate = AccessGate(authenticator: owner, defaults: defaults)
        let settings = ProtectedScopeSettings(gate: gate, scope: .app, reason: "Unlock")
        settings.enabled.wrappedValue = !initial
        XCTAssertEqual(settings.enabled.wrappedValue, initial)
        await fulfillment(of: [owner.requested], timeout: 5)
        await answer(result, owner: owner, settings: settings)
        XCTAssertEqual(settings.enabled.wrappedValue, expected)
        XCTAssertEqual(defaults.bool(forKey: AppSettingsKey.appLockEnabled), expected)
        XCTAssertTrue(settings.canChange)
    }

    private func answer(
        _ result: DeviceOwnerAuthResult, owner: PendingDeviceOwner, settings: ProtectedScopeSettings
    ) async {
        guard settings.isChanging else {
            XCTFail("The binding never started its change")
            return
        }
        let finished = expectation(description: "The binding finished its change")
        withObservationTracking {
            _ = settings.isChanging
        } onChange: {
            finished.fulfill()
        }
        owner.answer(result)
        await fulfillment(of: [finished], timeout: 5)
    }
}

@MainActor
private final class PendingDeviceOwner: DeviceOwnerAuthenticating {
    let requested = XCTestExpectation(description: "The system authentication was requested")
    private(set) var reasons: [String] = []
    private var reply: CheckedContinuation<DeviceOwnerAuthResult, Never>?
    private let currentAvailability: DeviceOwnerAuthAvailability

    init(availability: DeviceOwnerAuthAvailability = .available(.faceID)) {
        currentAvailability = availability
    }

    func availability() -> DeviceOwnerAuthAvailability { currentAvailability }

    func authenticate(reason: String) async -> DeviceOwnerAuthResult {
        reasons.append(reason)
        return await withCheckedContinuation {
            reply = $0
            requested.fulfill()
        }
    }

    func answer(_ result: DeviceOwnerAuthResult) {
        XCTAssertNotNil(reply, "No authentication is waiting for an answer")
        reply?.resume(returning: result)
        reply = nil
    }

    func cancel() { answer(.cancelled) }
}
