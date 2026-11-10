import Testing

@testable import UploadFeature

@Suite struct BulkPhotoActionControlsTests {
    @Test func theBarShowsTheShareOfCheckedPhotos() {
        #expect(BulkPhotoActionControls.progressFraction(processed: 0, total: 4) == 0)
        #expect(BulkPhotoActionControls.progressFraction(processed: 1, total: 4) == 0.25)
        #expect(BulkPhotoActionControls.progressFraction(processed: 4, total: 4) == 1)
    }

    @Test func aRunWithoutATotalShowsAnEmptyBar() {
        #expect(BulkPhotoActionControls.progressFraction(processed: 0, total: 0) == 0)
    }
}
