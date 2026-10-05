import PhotosCore
import XCTest

/// Which network path counts as expensive (cellular data or Personal Hotspot) for the backup's mobile-data setting.
final class LibraryNetworkPathTests: XCTestCase {
    func testTheSystemsExpensiveFlagDecides() {
        let cellular = LibraryNetworkPath(isSatisfied: true, isExpensive: true, availableInterfaces: [.cellular])
        XCTAssertTrue(LibraryNetworkState.isExpensive(cellular))
        let wiFi = LibraryNetworkPath(isSatisfied: true, availableInterfaces: [.wifi])
        XCTAssertFalse(LibraryNetworkState.isExpensive(wiFi))
    }

    func testVPNOverCellularDataIsExpensive() {
        let vpn = LibraryNetworkPath(
            isSatisfied: true, usesOtherInterface: true, availableInterfaces: [.other, .cellular])
        XCTAssertTrue(LibraryNetworkState.isExpensive(vpn))
    }

    func testVPNOverWiFiOrEthernetIsNotExpensive() {
        for physical in [LibraryNetworkInterfaceKind.wifi, .wiredEthernet] {
            let vpn = LibraryNetworkPath(
                isSatisfied: true, usesOtherInterface: true, availableInterfaces: [.other, physical])
            XCTAssertFalse(LibraryNetworkState.isExpensive(vpn), "\(physical)")
            let both = LibraryNetworkPath(
                isSatisfied: true, usesOtherInterface: true, availableInterfaces: [.other, .cellular, physical])
            XCTAssertFalse(LibraryNetworkState.isExpensive(both), "\(physical) next to cellular")
        }
    }

    func testCellularNextToATunnelThatThePathDoesNotUseKeepsTheSystemsAnswer() {
        let wiFi = LibraryNetworkPath(isSatisfied: true, availableInterfaces: [.other, .cellular])
        XCTAssertFalse(LibraryNetworkState.isExpensive(wiFi))
    }

    func testStateFromAPathKeepsReachabilityAndLowDataMode() {
        let state = LibraryNetworkState(
            path: LibraryNetworkPath(
                isSatisfied: false, isConstrained: true, usesOtherInterface: true,
                availableInterfaces: [.other, .cellular]))
        XCTAssertEqual(
            state, LibraryNetworkState(isReachable: false, isConstrained: true, isExpensive: true, isDetermined: true))
    }

    func testTheSharedStateStartsWithoutANetworkPath() {
        XCTAssertFalse(LibraryNetworkState.undetermined.isDetermined)
        XCTAssertTrue(LibraryNetworkState.undetermined.isReachable, "an unknown path is not offline")
        XCTAssertFalse(
            LibraryRuntimeState.shared.snapshot().network.isDetermined,
            "package tests install no platform network monitor")
    }
}
