import Foundation
import PhotosCore
import Testing
import UploadCore

@testable import ProtonDriveBackend

@Suite struct TrashedSeriesRestoreUnavailableTests {
    /// A journal that cannot open leaves the replay without a journal. A deliberate trash must then fail with the
    /// internal local-state failure instead of forgetting nothing.
    @Test func aReplayWithoutAJournalRefusesADeliberateTrash() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A directory cannot open as the journal database.
        let replay = TrashedSeriesRestoreReplay(url: directory, policy: .conservative)
        #expect(replay.journal == nil)

        do {
            try await replay.forget([PhotoUID(volumeID: "volume", nodeID: "node")])
            Issue.record("a replay without a journal must refuse the trash")
        } catch {
            #expect((error as? UploadCore.UploadError) == .internalFailure(.localStateUnavailable))
        }
        #expect(TrashedSeriesRestoreJournal.unavailable == .internalFailure(.localStateUnavailable))
    }
}
