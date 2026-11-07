import PhotoViewerCore
import PhotosCore
import Testing

@Suite struct ViewerInfoFileFieldsTests {
    @Test func aCompleteMetadataFillsEveryField() {
        let fields = ViewerInfoFileFields(
            metadata: PhotoMetadata(
                filename: "IMG_0001.HEIC", fileSize: 2_048, pixelWidth: 4_000, pixelHeight: 3_000,
                durationSeconds: 65),
            fallbackDuration: nil)

        #expect(fields.filename == "IMG_0001.HEIC")
        #expect(fields.dimensions == "4000 × 3000 (12.0 MP)")
        #expect(fields.fileSize == 2_048)
        #expect(fields.duration == "1:05")
    }

    @Test func anEmptyNameAndMissingValuesGiveNoField() {
        let fields = ViewerInfoFileFields(metadata: PhotoMetadata(filename: ""), fallbackDuration: nil)

        #expect(fields.filename == nil)
        #expect(fields.dimensions == nil)
        #expect(fields.fileSize == nil)
        #expect(fields.duration == nil)
        #expect(fields.device == nil)
    }

    @Test func deviceIsShownOnlyWhenNonempty() {
        #expect(ViewerInfoFileFields(metadata: PhotoMetadata(device: ""), fallbackDuration: nil).device == nil)
        #expect(
            ViewerInfoFileFields(metadata: PhotoMetadata(device: "Camera"), fallbackDuration: nil).device == "Camera")
    }

    @Test(arguments: [(0, 3_000), (4_000, 0), (-1, 3_000), (4_000, -5)])
    func aSideThatIsNotAboveZeroHidesTheDimensions(size: (Int, Int)) {
        let fields = ViewerInfoFileFields(
            metadata: PhotoMetadata(pixelWidth: size.0, pixelHeight: size.1), fallbackDuration: nil)

        #expect(fields.dimensions == nil)
    }

    @Test func aSizeOfZeroShowsAndANegativeSizeDoesNot() {
        #expect(ViewerInfoFileFields(metadata: PhotoMetadata(fileSize: 0), fallbackDuration: nil).fileSize == 0)
        #expect(ViewerInfoFileFields(metadata: PhotoMetadata(fileSize: -1), fallbackDuration: nil).fileSize == nil)
    }

    @Test func theItemDurationStandsInWhenMetadataIsMissingOrZero() {
        let none = PhotoMetadata()
        #expect(ViewerInfoFileFields(metadata: none, fallbackDuration: 9.6).duration == "0:10")
        let longer = PhotoMetadata(durationSeconds: 30)
        #expect(ViewerInfoFileFields(metadata: longer, fallbackDuration: 9).duration == "0:30")
        #expect(
            ViewerInfoFileFields(metadata: PhotoMetadata(durationSeconds: 0), fallbackDuration: 9).duration == "0:09")
        #expect(ViewerInfoFileFields(metadata: none, fallbackDuration: 0).duration == nil)
        #expect(
            ViewerInfoFileFields(metadata: PhotoMetadata(durationSeconds: 3_661), fallbackDuration: nil).duration
                == "61:01")
    }

    @Test(arguments: [1e300, Double.infinity, Double.nan])
    func invalidDurationDoesNotCreateARow(seconds: Double) {
        #expect(
            ViewerInfoFileFields(metadata: PhotoMetadata(durationSeconds: seconds), fallbackDuration: nil).duration
                == nil)
    }

    @Test func durationBoundsAndInvalidMetadataFallback() {
        #expect(PhotoDuration.roundedSeconds(Double(Int.max)) == nil)
        #expect(PhotoDuration.roundedSeconds(Double(Int.max).nextDown) != nil)
        #expect(PhotoDuration.roundedSeconds(-.infinity) == nil)
        #expect(PhotoDuration.roundedSeconds(-1) == nil)
        #expect(
            ViewerInfoFileFields(metadata: PhotoMetadata(durationSeconds: .nan), fallbackDuration: 9).duration
                == "0:09")
    }

    @Test func mediaTypeUsesMetadataThenTheItem() {
        #expect(ViewerInfoFileFields.mediaType(mimeType: "image/heic", fallback: "image/jpeg") == "image/heic")
        #expect(ViewerInfoFileFields.mediaType(mimeType: "", fallback: "image/jpeg") == "image/jpeg")
        #expect(ViewerInfoFileFields.mediaType(mimeType: nil, fallback: "") == nil)
    }
}
