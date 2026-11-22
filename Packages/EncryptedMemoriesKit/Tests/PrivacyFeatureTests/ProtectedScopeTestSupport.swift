import Foundation
import PhotosCore
import XCTest

@MainActor
class ProtectedScopeTestCase: XCTestCase {
    private var suite = ""
    var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "\(type(of: self)).\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }
}

@MainActor
final class PendingDeviceOwner: DeviceOwnerAuthenticating {
    var requested = XCTestExpectation(description: "The system authentication was requested")
    private(set) var reasons: [String] = []
    private var reply: CheckedContinuation<DeviceOwnerAuthResult, Never>?
    private let currentAvailability: DeviceOwnerAuthAvailability

    init(availability: DeviceOwnerAuthAvailability = .available(.faceID)) {
        currentAvailability = availability
    }

    func availability() -> DeviceOwnerAuthAvailability { currentAvailability }

    func authenticate(reason: String) async -> DeviceOwnerAuthResult {
        reasons.append(reason)
        return await withCheckedContinuation {
            reply = $0
            requested.fulfill()
        }
    }

    func answer(_ result: DeviceOwnerAuthResult) {
        XCTAssertNotNil(reply, "No authentication is waiting for an answer")
        reply?.resume(returning: result)
        reply = nil
    }

    func cancel() { answer(.cancelled) }
}
