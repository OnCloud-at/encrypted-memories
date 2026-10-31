import Testing
import UploadFeature

struct PendingExcludedPhotosEntryLatchTests {
    @Test func aPageWithoutExcludedPhotosShowsNoEntry() {
        var latch = PendingExcludedPhotosEntryLatch(count: 0)
        #expect(!latch.isShown)
        latch.update(count: 0)
        #expect(!latch.isShown)
    }

    @Test func theEntryAppearsWhenAPhotoIsExcludedWhileThePageShows() {
        var latch = PendingExcludedPhotosEntryLatch()
        latch.update(count: 1)
        #expect(latch.isShown)
    }

    /// The person puts the last photo back into the backup from the list: the entry stays, so the list stays open
    /// and shows its empty state.
    @Test func theEntryStaysAfterTheLastPhotoWentBackIntoTheBackup() {
        var latch = PendingExcludedPhotosEntryLatch(count: 2)
        latch.update(count: 1)
        latch.update(count: 0)
        #expect(latch.isShown)
    }

    @Test func aPageThatShowsAgainStartsFromTheCurrentCount() {
        var latch = PendingExcludedPhotosEntryLatch(count: 1)
        latch.update(count: 0)
        latch.reset(count: 0)
        #expect(!latch.isShown)
        latch.reset(count: 3)
        #expect(latch.isShown)
    }
}
