import Foundation
import Testing

@testable import PhotosCore

/// The shared preparation loop of the video viewers: it asks again after a rate limit and gives up on every other
/// failure at once.
@Suite("Video preparation retry")
struct VideoPreparationRetryTests {
    private let rateLimit = NSError(
        domain: "ProtonAuth", code: 429, userInfo: [NSLocalizedDescriptionKey: "HTTP 429 for /drive/x"])

    @Test func aRateLimitIsRetriedWithTheProductionWaitsAndThenSucceeds() async throws {
        let waits = Recorder()
        let attempts = Recorder()
        let value = try await VideoPreparationRetry.run(
            wait: { await waits.record($0) },
            attempt: {
                if await attempts.record(.zero) < 3 { throw rateLimit }
                return "stream"
            })
        #expect(value == "stream")
        #expect(await waits.durations == [.seconds(3), .seconds(8)])
        #expect(await attempts.count == 3)
    }

    @Test func aRateLimitThatLastsThrowsItAfterTheLastWait() async {
        let waits = Recorder()
        let attempts = Recorder()
        var thrown: (any Error)?
        do {
            _ = try await VideoPreparationRetry.run(
                wait: { await waits.record($0) },
                attempt: { () async throws -> String in
                    // A loop that does not advance through the waits ends here, with the wrong waits.
                    if await attempts.record(.zero) > 10 { throw CancellationError() }
                    throw rateLimit
                })
        } catch {
            thrown = error
        }
        let terminal = thrown.map { $0 as NSError }
        #expect(terminal?.domain == rateLimit.domain)
        #expect(terminal?.code == rateLimit.code)
        #expect(thrown.map(VideoPlaybackError.classify) == .quotaOrRateLimited)
        #expect(await waits.durations == [.seconds(3), .seconds(8), .seconds(20)])
        #expect(await attempts.count == 4, "the first attempt and one after each wait")
    }

    /// The iPhone viewer prepares its video here. Every failure that goes away by itself waits like a rate limit.
    @Test func everyFailureThatGoesAwayByItselfIsRetriedWithTheProductionWaits() async {
        let failures: [any Error] = [
            URLError(.timedOut), URLError(.networkConnectionLost), URLError(.cannotConnectToHost),
            URLError(.dnsLookupFailed), URLError(.cannotFindHost),
        ]
        for failure in failures {
            let waits = Recorder()
            let attempts = Recorder()
            await #expect(throws: (any Error).self) {
                try await VideoPreparationRetry.run(
                    wait: { await waits.record($0) },
                    attempt: { () async throws -> String in
                        if await attempts.record(.zero) > 10 { throw CancellationError() }
                        throw failure
                    })
            }
            #expect(await waits.durations == [.seconds(3), .seconds(8), .seconds(20)], "\(failure)")
            #expect(await attempts.count == 4, "\(failure)")
        }
    }

    /// Missing video information can mean that the video is gone (404, 410): one more attempt, then the answer.
    @Test func missingVideoInformationIsAskedAgainOnce() async {
        let failure = NSError(domain: "Proton", code: 404, userInfo: [NSLocalizedDescriptionKey: "HTTP 404 for /x"])
        let waits = Recorder()
        let attempts = Recorder()
        await #expect(throws: (any Error).self) {
            try await VideoPreparationRetry.run(
                wait: { await waits.record($0) },
                attempt: { () async throws -> String in
                    if await attempts.record(.zero) > 10 { throw CancellationError() }
                    throw failure
                })
        }
        #expect(await waits.durations == [.seconds(3)])
        #expect(await attempts.count == 2)
    }

    /// Another attempt would fail the same way: the first failure is the answer. The device says that it has no
    /// network for this app, a wrapped error says so, or the connection is refused for good.
    @Test func aFailureThatAnotherAttemptCannotChangeThrowsAtOnceWithoutAWait() async {
        // A recoverable outer error that wraps a device without a network is final, too.
        let wrapped: [any Error] = [
            URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
        ].map {
            NSError(
                domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                userInfo: [NSUnderlyingErrorKey: URLError($0)])
        }
        let failures: [any Error] =
            wrapped + [
                URLError(.notConnectedToInternet) as any Error,
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
                URLError(.dataNotAllowed), URLError(.internationalRoamingOff), URLError(.callIsActive),
                URLError(.serverCertificateUntrusted), URLError(.serverCertificateHasBadDate),
                URLError(.serverCertificateHasUnknownRoot), URLError(.serverCertificateNotYetValid),
                URLError(.clientCertificateRejected), URLError(.appTransportSecurityRequiresSecureConnection),
                URLError(.badURL), URLError(.unsupportedURL), URLError(.userAuthenticationRequired),
                URLError(.userCancelledAuthentication), URLError(.secureConnectionFailed),
                URLError(.clientCertificateRequired), URLError(.httpTooManyRedirects),
                URLError(.cannotDecodeContentData), URLError(.cannotDecodeRawData), URLError(.cancelled),
            ]
        for failure in failures {
            let waits = Recorder()
            let attempts = Recorder()
            await #expect(throws: (any Error).self) {
                try await VideoPreparationRetry.run(
                    wait: { await waits.record($0) },
                    attempt: { () async throws -> String in
                        await attempts.record(.zero)
                        throw failure
                    })
            }
            #expect(await waits.durations.isEmpty, "\(failure)")
            #expect(await attempts.count == 1, "\(failure)")
        }
    }

    /// A cancellation is no failure to repeat, whatever wait the policy offers.
    @Test func noWaitFollowsACancellation() {
        let offered: (VideoPlaybackError) -> [Duration] = { _ in [.seconds(1)] }
        for cancellation in [CancellationError() as any Error, URLError(.cancelled)] {
            #expect(
                VideoPreparationRetry.nextDelay(after: cancellation, retries: 0, delays: offered) == nil,
                "\(cancellation)")
        }
        #expect(VideoPreparationRetry.nextDelay(after: URLError(.timedOut), retries: 0, delays: offered) == .seconds(1))
    }

    @Test func everyOtherFailureThrowsAtOnceWithoutAWait() async {
        let failures: [any Error] = [
            NSError(domain: "AVFoundationErrorDomain", code: -11828),
            NSError(domain: "AVFoundationErrorDomain", code: -11800),
            NSError(domain: "Custom", code: 1),
        ]
        for failure in failures {
            let waits = Recorder()
            let attempts = Recorder()
            await #expect(throws: NSError.self) {
                try await VideoPreparationRetry.run(
                    wait: { await waits.record($0) },
                    attempt: {
                        await attempts.record(.zero)
                        throw failure
                    })
            }
            #expect(await waits.durations.isEmpty, "\(failure)")
            #expect(await attempts.count == 1, "\(failure)")
        }
    }

    @Test func aCancelledTaskDuringAWaitAsksNoAgain() async {
        let attempts = Recorder()
        let started = Recorder()
        let task = Task {
            try await VideoPreparationRetry.run(
                wait: { _ in
                    await started.record(.zero)
                    // The wait ends when the task is cancelled, like Task.sleep.
                    let limit = ContinuousClock.now + .seconds(10)
                    while !Task.isCancelled, ContinuousClock.now < limit { await Task.yield() }
                },
                attempt: {
                    await attempts.record(.zero)
                    throw rateLimit
                })
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while await started.count == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await started.count == 1, "the preparation never reached its wait")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await attempts.count == 1)
    }

    @Test func aCancellationOfTheAttemptIsNotRetried() async {
        let waits = Recorder()
        let attempts = Recorder()
        await #expect(throws: CancellationError.self) {
            try await VideoPreparationRetry.run(
                wait: { await waits.record($0) },
                attempt: { () async throws -> String in
                    await attempts.record(.zero)
                    throw CancellationError()
                })
        }
        #expect(await waits.count == 0)
        #expect(await attempts.count == 1)
    }

    /// Even a policy that offers a wait for every failure does not retry a cancellation.
    @Test func aCancellationIsNotRetriedEvenWhenThePolicyOffersAWait() async {
        let waits = Recorder()
        let attempts = Recorder()
        await #expect(throws: CancellationError.self) {
            try await VideoPreparationRetry.run(
                delays: { _ in [.zero] },
                wait: { await waits.record($0) },
                attempt: { () async throws -> String in
                    await attempts.record(.zero)
                    throw CancellationError()
                })
        }
        #expect(await waits.count == 0)
        #expect(await attempts.count == 1)
    }

    /// A failure of a cancelled attempt is rethrown at once, as it is; the loop neither waits nor turns it into a
    /// cancellation.
    @Test func aRateLimitOfACancelledAttemptIsRethrownAtOnceWithoutAWait() async {
        let waits = Recorder()
        var thrown: (any Error)?
        do {
            _ = try await VideoPreparationRetry.run(
                wait: { await waits.record($0) },
                attempt: { () async throws -> String in
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw rateLimit
                })
        } catch {
            thrown = error
        }
        #expect(!(thrown is CancellationError))
        #expect(thrown.map(VideoPlaybackError.classify) == .quotaOrRateLimited)
        #expect(await waits.count == 0)
    }
}

private actor Recorder {
    private(set) var durations: [Duration] = []
    private(set) var count = 0

    @discardableResult
    func record(_ duration: Duration) -> Int {
        count += 1
        if duration != .zero { durations.append(duration) }
        return count
    }
}
