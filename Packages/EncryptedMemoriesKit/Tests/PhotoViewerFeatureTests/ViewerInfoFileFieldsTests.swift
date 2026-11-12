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
        #expect(PhotoDuration.roundedSeconds(nil) == nil)
        #expect(PhotoDuration.roundedSeconds(0) == nil)
        #expect(PhotoDuration.roundedSeconds(-0.0) == nil)
        #expect(PhotoDuration.roundedSeconds(Double(Int.max)) == nil)
        #expect(PhotoDuration.roundedSeconds(Double(Int.max).nextDown) == 9_223_372_036_854_774_784)
        #expect(PhotoDuration.roundedSeconds(-.infinity) == nil)
        #expect(PhotoDuration.roundedSeconds(-1) == nil)
        #expect(
            ViewerInfoFileFields(metadata: PhotoMetadata(durationSeconds: .nan), fallbackDuration: 9).duration
                == "0:09")
    }

    @Test(arguments: [
        (Double.leastNonzeroMagnitude, 0),
        (0.49, 0),
        ((0.5).nextDown, 0),
        (0.5, 1),
        ((0.5).nextUp, 1),
        ((1.5).nextDown, 1),
        (1.5, 2),
        ((1.5).nextUp, 2),
        (59.5, 60),
        (3_600.49, 3_600),
        (3_600.5, 3_601),
        (2_592_000.5, 2_592_001),
    ])
    func durationRoundingKeepsBoundaryCases(value: (Double, Int)) {
        #expect(PhotoDuration.roundedSeconds(value.0) == value.1)
    }

    @Test func mediaTypeUsesMetadataThenTheItem() {
        #expect(ViewerInfoFileFields.mediaType(mimeType: "image/heic", fallback: "image/jpeg") == "image/heic")
        #expect(ViewerInfoFileFields.mediaType(mimeType: "", fallback: "image/jpeg") == "image/jpeg")
        #expect(ViewerInfoFileFields.mediaType(mimeType: nil, fallback: "") == nil)
    }
}
