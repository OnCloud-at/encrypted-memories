import Foundation
import Testing

@testable import ProtonDriveBackend

@Suite("Proton storage quota formatter")
struct ProtonStorageQuotaFormatterTests {
    @Test func matchesProtonsBinaryQuotaUnitsInGerman() {
        let quota = ProtonStorageQuotaFormatter.presentation(
            usedBytes: bytes(tebibytes: 1.94),
            maximumBytes: bytes(tebibytes: 6.2),
            locale: Locale(identifier: "de_AT")
        )

        #expect(quota.used == "1,94 TB")
        #expect(quota.maximum == "6,2 TB")
    }

    @Test func usesGigabytesBelowOneTebibyte() {
        let quota = ProtonStorageQuotaFormatter.presentation(
            usedBytes: bytes(gibibytes: 12.5),
            maximumBytes: bytes(gibibytes: 500),
            locale: Locale(identifier: "en_US")
        )

        #expect(quota.used == "12.50 GB")
        #expect(quota.maximum == "500 GB")
    }

    private func bytes(tebibytes: Double) -> Int64 {
        Int64((tebibytes * 1_099_511_627_776).rounded())
    }

    private func bytes(gibibytes: Double) -> Int64 {
        Int64((gibibytes * 1_073_741_824).rounded())
    }
}
