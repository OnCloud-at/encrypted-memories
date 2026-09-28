import Foundation
import ProtonDriveSDK
import Testing

@testable import ProtonDriveBackend

@Suite("Bounded device root claim download")
struct DeviceRootClaimDownloadStreamTests {
    @Test func rejectsOversizedWriteBeforeBufferGrowth() throws {
        let stream = DeviceRootClaimDownloadStream(limit: 4)
        try stream.write(Data("ab".utf8))
        #expect(throws: DeviceRootClaimDownloadStream.StreamError.limitExceeded) {
            try stream.write(Data("cde".utf8))
        }
        #expect(stream.bytes() == Data("ab".utf8))
    }

    @Test func rewritesWithinBoundAndRejectsOutsideSeek() throws {
        let stream = DeviceRootClaimDownloadStream(limit: 4)
        try stream.write(Data("abcd".utf8))
        #expect(try stream.seek(offset: -2, origin: .end) == 2)
        try stream.write(Data("XY".utf8))
        #expect(stream.bytes() == Data("abXY".utf8))
        #expect(throws: DeviceRootClaimDownloadStream.StreamError.invalidSeek) {
            try stream.seek(offset: 5, origin: .begin)
        }
    }
}
