import Foundation
import Testing
import UploadCore

@Suite struct BackupServiceRejectionTests {
    private static let start = Date(timeIntervalSince1970: 1_720_000_000)
    private static let hour: TimeInterval = 3600

    /// Parks at the given hours after the first one; the result after each park.
    private static func rounds(parkingAt hours: [Double]) -> [BackupServiceRejection] {
        var current: BackupServiceRejection?
        return hours.map { hours in
            let next = BackupServiceRejection.afterPark(current, at: start.addingTimeInterval(hours * hour))
            current = next
            return next
        }
    }

    @Test func aParkWithinADayStaysInItsRound() {
        let result = Self.rounds(parkingAt: [0, -48, -1, 1, 23.9])
        #expect(result.map(\.rounds) == [1, 1, 1, 1, 1])
        #expect(result.last?.firstRoundAt == Self.start)
        #expect(result.last?.lastRoundAt == Self.start)
        #expect(!result.contains { $0.stopsRetrying })
    }

    @Test func dailyRoundsStopOnlyOnceTheyCoverThreeDays() {
        let result = Self.rounds(parkingAt: [0, 24, 48, 72])
        #expect(result.map(\.rounds) == [1, 2, 3, 4])
        #expect(result.map(\.stopsRetrying) == [false, false, false, true])
    }

    @Test func threeRoundsOverThreeDaysStop() {
        let result = Self.rounds(parkingAt: [0, 36, 72])
        #expect(result.map(\.rounds) == [1, 2, 3])
        #expect(result.map(\.stopsRetrying) == [false, false, true])
    }

    @Test func twoRoundsNeverStopEvenAfterThreeDays() {
        let result = Self.rounds(parkingAt: [0, 80])
        #expect(result.map(\.rounds) == [1, 2])
        #expect(!result.contains { $0.stopsRetrying })
    }

    @Test func manyParksOnOneDayNeverStop() {
        let result = Self.rounds(parkingAt: (0..<50).map { Double($0) * 0.4 })
        #expect(result.last?.rounds == 1)
        #expect(!result.contains { $0.stopsRetrying })
    }

    @Test func aRecordWithoutRefusalsKeepsItsStoredFormat() throws {
        let plain = BackupIssueRecord(kind: .remoteService, detail: "detail")
        let payload = try #require(
            Data(base64Encoded: String(plain.persistedValue.dropFirst(BackupIssueRecord.storagePrefix.count))))
        #expect(!String(decoding: payload, as: UTF8.self).contains("serviceRejection"))

        let refused = BackupIssueRecord(
            kind: .remoteService, detail: "detail",
            serviceRejection: .init(rounds: 2, firstRoundAt: Self.start, lastRoundAt: Self.start))
        #expect(BackupIssueRecord.decode(refused.persistedValue) == refused)
        #expect(BackupIssueRecord.decode(plain.persistedValue) == plain)
    }
}
