import BackgroundTasks
import Foundation
import Testing

@testable import EncryptedMemoriesMobile

@MainActor @Suite struct MobileContinuedBackupTaskTests {
    @Test func theRequestRunsNowOrFailsAndAsksForNoExtraResources() {
        let identifier = PhotoBackupContinuedTask.identifierPrefix + "test"
        let request = PhotoBackupContinuedTask.request(identifier: identifier)
        #expect(request.identifier == identifier)
        #expect(request.strategy == .fail, "a queued request could start later without the person")
        #expect(request.requiredResources.isEmpty, "no GPU")
    }

    @Test func theIdentifiersMatchTheDeclaredWildcard() throws {
        let declared = try #require(
            Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        #expect(declared.contains(PhotoBackupContinuedTask.identifierPrefix + "*"))
    }
}
