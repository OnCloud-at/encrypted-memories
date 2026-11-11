import PhotosCore
import Testing

@Suite struct StoreLookupTests {
    private struct OtherReadError: Error {}

    @Test func aStoredValueIsFound() {
        #expect(StoreLookup(catching: { 7 }) == .found(7))
    }

    @Test func aCompleteReadWithoutAValueIsAbsent() {
        #expect(StoreLookup<Int>(catching: { nil }) == .absent)
    }

    @Test func aStoredNilIsFoundAndOnlyAMissingValueIsAbsent() {
        #expect(StoreLookup<Int?>(catching: { .some(nil) }) == .found(nil))
        #expect(StoreLookup<Int?>(catching: { nil }) == .absent)
    }

    @Test func aFailedReadIsUnknownAndNeverAbsent() {
        #expect(StoreLookup<Int>(catching: { throw SQLiteStoreUnknownReadError() }) == .unknown)
    }

    @Test func everyOtherThrownErrorIsUnknownAndNeverAbsent() {
        #expect(StoreLookup<Int>(catching: { throw OtherReadError() }) == .unknown)
        #expect(StoreLookup<Int>(catching: { throw CancellationError() }) == .unknown)
    }
}
