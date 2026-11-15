import PhotosCore
import XCTest

@testable import EncryptedMemoriesMobile

/// The offline UI test scenario sets the network to unreachable while the real path monitor also reports paths. On a
/// loaded runner the monitor's first path can arrive after the scenario started, as in queue run 43681214842.
final class MobileFixtureOfflineNetworkTests: XCTestCase {
    @MainActor func testTheOfflineScenarioStaysOfflineWhenAPlatformPathArrivesLater() async throws {
        let state = LibraryRuntimeState.makeProcessState()
        let offline = MobileFixtureOfflineNetwork(state: state)
        // The platform reports a usable path after the scenario started, then once more.
        for _ in 0..<2 {
            try await Task.sleep(for: .milliseconds(50))
            state.update { $0.network = LibraryNetworkState(isReachable: true) }
        }
        let stayedOffline = try await pollUntil(timeout: .seconds(2)) { !state.snapshot().network.isReachable }
        XCTAssertTrue(stayedOffline, "a later platform path made the offline scenario reachable")
        XCTAssertTrue(state.snapshot().network.isDetermined)
        withExtendedLifetime(offline) {}
    }
}
