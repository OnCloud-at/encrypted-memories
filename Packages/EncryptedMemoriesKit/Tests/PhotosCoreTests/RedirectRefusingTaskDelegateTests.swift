import Foundation
import XCTest

@testable import PhotosCore

final class RedirectRefusingTaskDelegateTests: XCTestCase {
    func testEveryRedirectIsDeclinedWhateverItsStatusOrTarget() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = try XCTUnwrap(URL(string: "https://drive.example/api/upload"))
        let task = session.dataTask(with: origin)

        for status in [301, 302, 303, 307, 308] {
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: origin, statusCode: status, httpVersion: nil,
                    headerFields: ["Location": "https://other.example/steal"]))
            for target in ["https://other.example/steal", "https://drive.example/elsewhere"] {
                let answer = await RedirectRefusingTaskDelegate.shared.urlSession(
                    session, task: task, willPerformHTTPRedirection: response,
                    newRequest: URLRequest(url: try XCTUnwrap(URL(string: target))))
                XCTAssertNil(answer, "status \(status) to \(target) must not be followed")
            }
        }
    }
}
