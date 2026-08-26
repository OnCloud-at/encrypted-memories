import Testing

@testable import DesignSystemCore

@Suite struct LibraryConnectivityBannerStateTests {
    @Test func offlineOutranksTheRestoredPulse() {
        #expect(
            LibraryConnectivityBannerState.resolve(
                isOnline: false,
                didRecentlyRestoreConnection: true
            ) == .offline
        )
    }

    @Test func restoredIsBrieflyVisibleAfterConnectivityReturns() {
        #expect(
            LibraryConnectivityBannerState.resolve(
                isOnline: true,
                didRecentlyRestoreConnection: true
            ) == .connectionRestored
        )
    }

    @Test func routineOnlineStateDoesNotOccupyTheBanner() {
        #expect(
            LibraryConnectivityBannerState.resolve(
                isOnline: true,
                didRecentlyRestoreConnection: false
            ) == .hidden
        )
    }
}
