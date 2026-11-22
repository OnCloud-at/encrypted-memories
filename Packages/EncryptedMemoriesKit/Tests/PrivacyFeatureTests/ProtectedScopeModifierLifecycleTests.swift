#if canImport(AppKit)
    import AppKit
    import DesignSystemCore
    import Observation
    import PhotosCore
    import PrivacyFeature
    import SwiftUI
    import XCTest

    @MainActor
    final class ProtectedScopeModifierLifecycleTests: ProtectedScopeTestCase {
        func testCoveredContentIsDisabledAndDoesNotReceiveHits() async throws {
            let owner = PendingDeviceOwner()
            let gate = AccessGate(authenticator: owner, defaults: defaults)
            let child = area("isolation")
            let state = HostState(gate: gate, scope: child)
            let probe = Probe()
            let host = makeHost(state: state, probe: probe)
            defer { host.close() }
            await fulfillment(of: [probe.appeared], timeout: 5)
            XCTAssertEqual(probe.isEnabled, false)
            XCTAssertEqual(probe.isCovered, true)
            XCTAssertFalse(host.hitReachesProtectedContent())

            await unlock(child, gate: gate, owner: owner)
            host.layout()
            await fulfillment(of: [probe.enabled], timeout: 5)
            XCTAssertEqual(probe.isEnabled, true)
            XCTAssertEqual(probe.isCovered, false)
            XCTAssertTrue(host.hitReachesProtectedContent())
        }

        func testCoveringTheContentRunsItsCoverActionEachTime() async throws {
            let owner = PendingDeviceOwner()
            let gate = AccessGate(authenticator: owner, defaults: defaults)
            let child = area("cover-action")
            let state = HostState(gate: gate, scope: child)
            let probe = Probe()
            let host = makeHost(state: state, probe: probe)
            defer { host.close() }
            await fulfillment(of: [probe.appeared], timeout: 5)
            XCTAssertEqual(probe.coverActions, 1, "Content that appears covered stops its playback")
            await unlock(child, gate: gate, owner: owner)
            host.layout()
            XCTAssertEqual(probe.coverActions, 1, "Uncovering must not run the action")
            state.snapshot = true
            host.layout()
            for _ in 0..<50 where probe.coverActions < 2 { await Task.yield() }
            XCTAssertEqual(probe.coverActions, 2)
        }

        func testDetachingARetainedHierarchyReleasesItsPresence() async throws {
            let owner = PendingDeviceOwner()
            let gate = AccessGate(authenticator: owner, defaults: defaults)
            let child = area("retained")
            let state = HostState(gate: gate, scope: child)
            let probe = Probe()
            let host = makeHost(state: state, probe: probe)
            defer { host.close() }
            await fulfillment(of: [probe.appeared], timeout: 5)
            await unlock(child, gate: gate, owner: owner)
            let locked = observeRelock(child, gate: gate)
            host.window.contentView = nil
            await fulfillment(of: [probe.disappeared, locked], timeout: 5)
            XCTAssertFalse(gate.admits(child))
            withExtendedLifetime(host.view) {}
        }

        func testAnInactiveAreaAsksOnlyAfterItBecomesActive() async throws {
            defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
            let owner = PendingDeviceOwner()
            let gate = AccessGate(authenticator: owner, defaults: defaults)
            let state = HostState(gate: gate, scope: .app)
            let probe = Probe()
            let host = makeHost(state: state, probe: probe)
            defer { host.close() }
            await fulfillment(of: [probe.appeared], timeout: 5)
            guard probe.appearances == 1 else { return }
            XCTAssertTrue(owner.reasons.isEmpty)

            state.phase = .active
            host.layout()
            await fulfillment(of: [owner.requested], timeout: 5)
            guard owner.reasons.count == 1 else { return }
            owner.answer(.cancelled)
            XCTAssertEqual(probe.appearances, 1)
        }

        func testASnapshotDoesNotAskUntilForegroundCoverageEnds() async throws {
            defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
            let owner = PendingDeviceOwner()
            owner.requested.isInverted = true
            let gate = AccessGate(authenticator: owner, defaults: defaults)
            let state = HostState(gate: gate, scope: .app, phase: .active)
            state.snapshot = true
            let probe = Probe()
            let host = makeHost(state: state, probe: probe)
            defer { host.close() }
            await fulfillment(of: [probe.appeared], timeout: 5)
            await fulfillment(of: [owner.requested], timeout: 0.1)
            XCTAssertTrue(owner.reasons.isEmpty, "A snapshot must never start authentication")
            guard owner.reasons.isEmpty else {
                owner.answer(.cancelled)
                return
            }
            owner.requested = expectation(description: "The foreground cover asks")
            state.snapshot = false
            host.layout()
            await fulfillment(of: [owner.requested], timeout: 5)
            guard owner.reasons.count == 1 else { return }
            owner.answer(.cancelled)
        }

        func testAParentUnlockStartsTheChildPromptWithoutAPhaseChange() async throws {
            defaults.set(true, forKey: AppSettingsKey.appLockEnabled)
            let owner = PendingDeviceOwner()
            let gate = AccessGate(authenticator: owner, defaults: defaults)
            let child = area("child", parent: .app)
            let state = HostState(gate: gate, scope: child, phase: .active)
            let probe = Probe()
            let host = makeHost(state: state, probe: probe)
            defer { host.close() }
            await fulfillment(of: [probe.appeared], timeout: 5)
            guard probe.appearances == 1 else { return }
            XCTAssertTrue(owner.reasons.isEmpty)

            let parent = Task { await gate.unlock(.app, reason: "Parent") }
            await fulfillment(of: [owner.requested], timeout: 5)
            guard owner.reasons.count == 1 else { return }
            let childRequested = expectation(description: "The child asks after its parent opens")
            owner.requested = childRequested
            owner.answer(.success)
            let parentResult = await parent.value
            XCTAssertEqual(parentResult, .unlocked)
            host.layout()

            await fulfillment(of: [childRequested], timeout: 5)
            guard owner.reasons.count == 2 else { return }
            XCTAssertEqual(owner.reasons, ["Parent", "Unlock"])
            XCTAssertFalse(gate.admits(child), "The parent must not open the child")
            owner.answer(.cancelled)
            XCTAssertEqual(state.phase, .active)
        }

        func testRemovingTheLastViewRelocksItsArea() async throws {
            let owner = PendingDeviceOwner()
            let gate = AccessGate(authenticator: owner, defaults: defaults)
            let child = area("last")
            let state = HostState(gate: gate, scope: child)
            let probe = Probe()
            let host = makeHost(state: state, probe: probe)
            defer { host.close() }
            await fulfillment(of: [probe.appeared], timeout: 5)
            guard probe.appearances == 1 else { return }
            await unlock(child, gate: gate, owner: owner)
            XCTAssertTrue(gate.admits(child))

            let locked = observeRelock(child, gate: gate)
            state.isPresented = false
            host.layout()
            await fulfillment(of: [probe.disappeared, locked], timeout: 5)
            XCTAssertFalse(gate.admits(child))
        }

        func testChangingAreaMovesThePresenceWithoutReplacingTheContent() async throws {
            let owner = PendingDeviceOwner()
            let gate = AccessGate(authenticator: owner, defaults: defaults)
            let first = area("first")
            let second = area("second")
            let state = HostState(gate: gate, scope: first)
            let probe = Probe()
            let host = makeHost(state: state, probe: probe)
            defer { host.close() }
            await fulfillment(of: [probe.appeared], timeout: 5)
            guard probe.appearances == 1 else { return }
            await unlock(first, gate: gate, owner: owner)

            let firstLocked = observeRelock(first, gate: gate)
            state.scope = second
            host.layout()
            await fulfillment(of: [firstLocked], timeout: 5)
            XCTAssertFalse(gate.admits(first))
            XCTAssertEqual(probe.appearances, 1)
            owner.requested = expectation(description: "The second area asks")
            await unlock(second, gate: gate, owner: owner)
            let secondLocked = observeRelock(second, gate: gate)
            state.isPresented = false
            host.layout()
            await fulfillment(of: [secondLocked], timeout: 5)
            XCTAssertFalse(gate.admits(second))
        }

        func testChangingGateMovesThePresence() async throws {
            let firstOwner = PendingDeviceOwner()
            let firstGate = AccessGate(authenticator: firstOwner, defaults: defaults)
            let secondOwner = PendingDeviceOwner()
            let secondGate = AccessGate(authenticator: secondOwner, defaults: defaults)
            let child = area("gate")
            let state = HostState(gate: firstGate, scope: child)
            let probe = Probe()
            let host = makeHost(state: state, probe: probe)
            defer { host.close() }
            await fulfillment(of: [probe.appeared], timeout: 5)
            guard probe.appearances == 1 else { return }
            await unlock(child, gate: firstGate, owner: firstOwner)

            let firstLocked = observeRelock(child, gate: firstGate)
            state.gate = secondGate
            host.layout()
            await fulfillment(of: [firstLocked], timeout: 5)
            XCTAssertFalse(firstGate.admits(child))
            await unlock(child, gate: secondGate, owner: secondOwner)
            let secondLocked = observeRelock(child, gate: secondGate)
            state.isPresented = false
            host.layout()
            await fulfillment(of: [secondLocked], timeout: 5)
            XCTAssertFalse(secondGate.admits(child))
            XCTAssertEqual(probe.appearances, 1)
        }

        func testAnInactiveOnlyChangeKeepsTheAreaOpenAndMounted() async throws {
            let owner = PendingDeviceOwner()
            let gate = AccessGate(authenticator: owner, defaults: defaults)
            let child = area("phase")
            let state = HostState(gate: gate, scope: child)
            let probe = Probe()
            let host = makeHost(state: state, probe: probe)
            defer { host.close() }
            await fulfillment(of: [probe.appeared], timeout: 5)
            guard probe.appearances == 1 else { return }
            await unlock(child, gate: gate, owner: owner)
            state.phase = .active
            host.layout()
            state.phase = .inactive
            host.layout()
            XCTAssertTrue(gate.admits(child))
            XCTAssertEqual(probe.appearances, 1)
            XCTAssertEqual(owner.reasons.count, 1)
        }

        private func area(_ name: String, parent: ProtectedScope? = nil) -> ProtectedScope {
            ProtectedScope(
                id: ProtectedScopeID("test.\(name)"), parent: parent, policy: .standardChild,
                enablement: ProtectedScopeEnablement(key: "test.\(name).enabled", defaultValue: true))
        }

        private func unlock(_ scope: ProtectedScope, gate: AccessGate, owner: PendingDeviceOwner) async {
            let authentication = Task { await gate.unlock(scope, reason: "Unlock") }
            await fulfillment(of: [owner.requested], timeout: 5)
            guard !owner.reasons.isEmpty else { return }
            owner.answer(.success)
            let result = await authentication.value
            XCTAssertEqual(result, .unlocked)
        }

        private func observeRelock(_ scope: ProtectedScope, gate: AccessGate) -> XCTestExpectation {
            let locked = expectation(description: "The area relocks")
            withObservationTracking {
                _ = gate.state(of: scope)
            } onChange: {
                locked.fulfill()
            }
            return locked
        }

        private func makeHost(state: HostState, probe: Probe) -> Host {
            _ = NSApplication.shared
            let view = NSHostingView(rootView: Root(state: state, probe: probe))
            let window = NSWindow(
                contentRect: CGRect(x: -10_000, y: -10_000, width: 320, height: 240),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            let host = Host(window: window, view: view)
            host.layout()
            return host
        }

        @MainActor private struct Host {
            let window: NSWindow
            let view: NSHostingView<Root>
            func layout() {
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
            }
            func hitReachesProtectedContent() -> Bool {
                guard let target = view.rootView.probe.button else { return false }
                let point = view.convert(CGPoint(x: 8, y: 8), from: target)
                guard let hit = view.hitTest(point) else { return false }
                return hit === target || hit.isDescendant(of: target)
            }
            func close() {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
        }

        @MainActor @Observable final class HostState {
            var gate: AccessGate
            var scope: ProtectedScope
            var phase: ScenePhase
            var isPresented = true
            var snapshot = false
            init(gate: AccessGate, scope: ProtectedScope, phase: ScenePhase = .inactive) {
                self.gate = gate
                self.scope = scope
                self.phase = phase
            }
        }

        @MainActor private final class Probe {
            let appeared = XCTestExpectation(description: "The content appears")
            let disappeared = XCTestExpectation(description: "The content disappears")
            var appearances = 0
            var coverActions = 0
            var isEnabled: Bool?
            var isCovered: Bool?
            weak var button: NSButton?
            let enabled = XCTestExpectation(description: "The protected content becomes enabled")
        }

        private struct NativeAction: NSViewRepresentable {
            let probe: Probe
            func makeNSView(context: Context) -> NSButton {
                let button = NSButton(title: "Protected action", target: nil, action: nil)
                probe.button = button
                return button
            }
            func updateNSView(_ button: NSButton, context: Context) {
                button.isEnabled = context.environment.isEnabled
            }
        }

        private struct EnabledProbe: View {
            @Environment(\.isEnabled) private var isEnabled
            @Environment(\.protectedContentIsCovered) private var isCovered
            let probe: Probe
            var body: some View {
                Color.clear
                    .onAppear {
                        probe.isEnabled = isEnabled
                        probe.isCovered = isCovered
                    }
                    .onChange(of: isCovered) { _, covered in probe.isCovered = covered }
                    .onChange(of: isEnabled) { _, enabled in
                        probe.isEnabled = enabled
                        if enabled { probe.enabled.fulfill() }
                    }
            }
        }

        private struct Root: View {
            let state: HostState
            let probe: Probe
            var body: some View {
                Group {
                    if state.isPresented {
                        NativeAction(probe: probe)
                            .accessibilityLabel("Protected action")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.red)
                            .background(EnabledProbe(probe: probe))
                            .onAppear {
                                probe.appearances += 1
                                probe.appeared.fulfill()
                            }
                            .onDisappear { probe.disappeared.fulfill() }
                            .onProtectedCover { covered in if covered { probe.coverActions += 1 } }
                            .protectedScope(
                                state.scope, gate: state.gate, unlockTitle: "Unlock", accessibilityLabel: "Locked",
                                reason: "Unlock", snapshot: state.snapshot, scenePhase: state.phase)
                    } else {
                        Color.clear
                    }
                }
            }
        }
    }
#endif
