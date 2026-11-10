import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

/// The event probe of an idle library, counted over one virtual hour (#1099). The foreground policy probes every five
/// seconds; each probe is one request, so the rate is the request rate of an idle library. A slower interval would
/// lower these counts; whether to slow it down is the owner's choice and these tests do not decide it.
@Suite struct LibraryChangeMonitorProbeRateTests {
    @Test func theForegroundPolicyProbesEveryFiveSeconds() {
        #expect(LibraryChangePollingPolicy.foreground.interval == .seconds(5))
    }

    #if DEBUG
        @Test(.timeLimit(.minutes(1)), arguments: [(5, 720), (15, 240), (30, 120)])
        func anIdleLibraryIsProbedOncePerIntervalAndNeverRefreshed(seconds: Int, probesPerHour: Int) async {
            let clock = TimelineRefreshTestClock()
            let provider = IdleProbeCounter()
            let interval = Duration.seconds(seconds)
            let monitor = LibraryChangeMonitor(clock: clock.dependency)
            await monitor.start(
                provider: provider,
                policy: LibraryChangePollingPolicy(interval: interval, failureInterval: .seconds(30)),
                initialToken: "idle"
            ) {
                Issue.record("An unchanged token must not start a refresh")
                return .refreshed(token: "idle")
            }

            // The seeded baseline delays the first probe by one interval; each advance then sends one probe.
            #expect(await clock.waitForSleepCount(1))
            for probe in 1...probesPerHour {
                clock.advance(by: interval)
                #expect(await clock.waitForSleepCount(probe + 1), "probe \(probe) did not finish")
            }
            #expect(await provider.count == probesPerHour)
            await monitor.stop()
        }
    #endif
}

private actor IdleProbeCounter: LibraryChangeTokenProvider {
    private(set) var count = 0

    func libraryChangeToken() async throws -> String {
        count += 1
        return "idle"
    }
}
