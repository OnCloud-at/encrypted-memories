import Foundation
import Testing

@testable import DeviceRootCore

@Suite("Device root paths")
struct DeviceRootPathTests {
    @Test func acceptsOnlyRelativeStateAndIndexPaths() throws {
        #expect(try DeviceRootPath("State/account-state.json").rawValue == "State/account-state.json")
        #expect(try DeviceRootPath("Index/device-1/abc123.segment").rawValue == "Index/device-1/abc123.segment")
        #expect(try DeviceRootPath("State").rawValue == "State")
    }

    @Test(
        arguments: [
            "", "/State/state", "Other/state", "State//state", "State/../Index/foreign",
            "Index/./file", "Index/device\\file", "State/file\u{0000}", "State/é",
        ]
    )
    func rejectsEscapesAndUnexpectedNames(_ input: String) {
        #expect(throws: DeviceRootPathError.self) {
            try DeviceRootPath(input)
        }
    }

    @Test func rejectsOverlongComponents() {
        #expect(throws: DeviceRootPathError.self) {
            try DeviceRootPath("Index/" + String(repeating: "a", count: 256))
        }
    }
}
