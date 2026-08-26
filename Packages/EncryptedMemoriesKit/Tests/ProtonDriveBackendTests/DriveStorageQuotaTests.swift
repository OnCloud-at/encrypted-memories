import Foundation
import Testing

@testable import ProtonDriveBackend

@Suite("Drive storage quota")
struct DriveStorageQuotaTests {
    @Test func driveAllocationWinsOverAccountAllocation() throws {
        let quota = try decode([
            "UsedSpace": 900,
            "MaxSpace": 1_000,
            "UsedBaseSpace": 600,
            "MaxBaseSpace": 600,
            "UsedDriveSpace": 300,
            "MaxDriveSpace": 700,
        ])

        #expect(quota == DriveStorageQuota(usedBytes: 300, maxBytes: 700))
    }

    @Test func oldAccountResponseFallsBackToAccountAllocation() throws {
        let quota = try decode(["UsedSpace": 400, "MaxSpace": 800])

        #expect(quota == DriveStorageQuota(usedBytes: 400, maxBytes: 800))
    }

    @Test func partiallyAvailableDriveAllocationFallsBackFieldByField() throws {
        let missingDriveUsageDefaultsToZero = try decode([
            "UsedSpace": 410,
            "MaxSpace": 900,
            "MaxBaseSpace": 150,
            "MaxDriveSpace": 750,
        ])
        let maxFallback = try decode([
            "UsedSpace": 410,
            "MaxSpace": 900,
            "MaxBaseSpace": 150,
            "UsedDriveSpace": 320,
        ])

        #expect(missingDriveUsageDefaultsToZero == DriveStorageQuota(usedBytes: 0, maxBytes: 750))
        #expect(maxFallback == DriveStorageQuota(usedBytes: 320, maxBytes: 900))
    }

    @Test func explicitZeroDriveMaximumIsNotReplacedByAccountMaximum() throws {
        let quota = try decode([
            "UsedSpace": 400,
            "MaxSpace": 800,
            "MaxBaseSpace": 800,
            "UsedDriveSpace": 0,
            "MaxDriveSpace": 0,
        ])

        #expect(quota == DriveStorageQuota(usedBytes: 0, maxBytes: 0))
    }

    private func decode(_ storage: [String: Int64]) throws -> DriveStorageQuota? {
        var user: [String: Any] = ["Keys": []]
        storage.forEach { user[$0.key] = $0.value }
        let data = try JSONSerialization.data(withJSONObject: ["User": user])
        return try DriveSession.decodeDriveStorageQuota(users: data)
    }
}
