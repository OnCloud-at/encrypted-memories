import PhotoLibraryBackupAdapter
import Testing
import UploadCore

@testable import EncryptedMemoriesMobile

/// How a place of the continued backup question reacts to its scene and to the rules' decision (#1108).
@MainActor @Suite struct MobileContinuedBackupPromptModifierTests {
    private typealias Modifier = MobileContinuedBackupPromptModifier
    private typealias Asker = PhotoLibraryContinuedBackupPrompt.Asker

    @MainActor private final class MarkerBox {
        var value = false
        var marker: Asker.Marker { Asker.Marker(isSet: { self.value }, set: { self.value = $0 }) }
    }

    private let start = ContinuousClock.now

    private var busy: BackupStatus {
        var status = BackupStatus()
        status.phase = .uploading
        status.totalConsidered = 1_000
        status.remainingCount = 500
        status.hasOutstandingWork = true
        return status
    }

    @Test func itSleepsThroughTheCalmTimeInSteps() {
        #expect(
            Modifier.pause(after: .wait(.milliseconds(1_700))) == Modifier.coverCheckInterval,
            "a cover that comes and goes within the calm time is seen")
        #expect(Modifier.pause(after: .wait(.milliseconds(200))) == .milliseconds(200))
        #expect(Modifier.pause(after: .held) == Modifier.coverCheckInterval)
    }

    @Test func itStopsLookingWhenItAsksOrCannotAsk() {
        #expect(Modifier.pause(after: .ask) == nil)
        #expect(Modifier.pause(after: .none) == nil, "only a change of the backup or the scene can let it ask")
    }

    @Test func anInactiveSceneAsksNothingAndKeepsTheQuestion() {
        let marker = MarkerBox()
        let asker = Asker(claim: .init(), marker: marker.marker)
        #expect(Modifier.sceneChanged(to: .active, asker: asker, at: start))
        #expect(Modifier.sceneChanged(to: .inactive, asker: asker, at: start + .seconds(1)))
        #expect(
            asker.next(busy, estimatedBytes: nil, isTaskActive: false, at: start + .seconds(5)) == .none,
            "no question under Control Center")

        #expect(Modifier.sceneChanged(to: .active, asker: asker, at: start + .seconds(6)))
        #expect(asker.next(busy, estimatedBytes: nil, isTaskActive: false, at: start + .seconds(8)) == .ask)
        #expect(Modifier.sceneChanged(to: .inactive, asker: asker, at: start + .seconds(9)), "the question stays")
        #expect(asker.isPresenting)
        #expect(!marker.value)

        #expect(!Modifier.sceneChanged(to: .background, asker: asker, at: start + .seconds(10)), "leaving closes it")
        #expect(marker.value, "and counts as Not Now")
    }
}
