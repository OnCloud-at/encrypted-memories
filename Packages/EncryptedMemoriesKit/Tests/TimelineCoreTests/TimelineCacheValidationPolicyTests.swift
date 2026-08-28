import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct TimelineCacheValidationPolicyTests {
    @Test func matchingStableTokenValidatesCachedInventory() async {
        let repository = CacheValidationRepository(cachedToken: "event-4", currentToken: "event-4")

        #expect(
            await TimelineCacheValidationPolicy.validate(
                snapshot: snapshot(token: "event-4"), repository: repository
            ) == .validated(token: "event-4"))
        #expect(await repository.probeCount == 1)
    }

    @Test func changedTokenRequiresRefreshAndPreservesOldBaseline() async {
        let repository = CacheValidationRepository(cachedToken: "event-4", currentToken: "event-5")

        #expect(
            await TimelineCacheValidationPolicy.validate(
                snapshot: snapshot(token: "event-4"), repository: repository
            ) == .refreshRequired(monitorBaseline: "event-5"))
    }

    @Test func missingPersistedTokenFailsClosedButStillCapturesMonitorBaseline() async {
        let repository = CacheValidationRepository(cachedToken: nil, currentToken: "event-5")

        #expect(
            await TimelineCacheValidationPolicy.validate(
                snapshot: snapshot(token: nil), repository: repository
            ) == .refreshRequired(monitorBaseline: "event-5"))
        #expect(await repository.probeCount == 1)
    }

    @Test func failedProbeFailsClosed() async {
        let repository = CacheValidationRepository(cachedToken: "event-4", currentToken: nil)

        #expect(
            await TimelineCacheValidationPolicy.validate(
                snapshot: snapshot(token: "event-4"), repository: repository
            ) == .refreshRequired(monitorBaseline: "event-4"))
    }

    @Test func terminalProbePreservesRecoveryMeaning() async {
        #expect(
            await TimelineCacheValidationPolicy.validate(
                snapshot: snapshot(token: "event-4"),
                repository: TerminalCacheValidationRepository()
            ) == .terminalFailure
        )
    }

    private func snapshot(token: String?) -> CachedTimelineSnapshot {
        CachedTimelineSnapshot(sections: [], validationToken: token)
    }
}

private actor CacheValidationRepository: PhotosRepository, LibraryChangeTokenProvider {
    let cachedToken: String?
    let currentToken: String?
    private(set) var probeCount = 0

    init(cachedToken: String?, currentToken: String?) {
        self.cachedToken = cachedToken
        self.currentToken = currentToken
    }

    func loadTimeline() async throws -> [TimelineSection] { [] }
    func cachedTimelineValidationToken() async -> String? { cachedToken }

    func libraryChangeToken() async throws -> String {
        probeCount += 1
        guard let currentToken else { throw ProbeFailure() }
        return currentToken
    }
}

private struct ProbeFailure: Error {}

private struct TerminalCacheValidationRepository: PhotosRepository, LibraryChangeTokenProvider {
    func loadTimeline() async throws -> [TimelineSection] { [] }

    func libraryChangeToken() async throws -> String {
        throw TerminalCacheValidationError()
    }
}

private struct TerminalCacheValidationError: LibraryChangeTerminalError {}
