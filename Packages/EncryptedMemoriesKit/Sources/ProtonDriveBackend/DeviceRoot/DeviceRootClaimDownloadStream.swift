import Foundation
import ProtonDriveSDK

/// Bounds actual decoded claim bytes even when remote size metadata is incorrect.
final class DeviceRootClaimDownloadStream: SeekableOutputStream, @unchecked Sendable {
    enum StreamError: Error, Equatable {
        case limitExceeded
        case invalidSeek
        case closed
    }

    private let limit: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var position = 0
    private var isClosed = false

    init(limit: Int) {
        self.limit = limit
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            guard !isClosed else { throw StreamError.closed }
            let (end, overflow) = position.addingReportingOverflow(data.count)
            guard !overflow, end <= limit else { throw StreamError.limitExceeded }
            if buffer.count < end {
                buffer.append(contentsOf: repeatElement(UInt8(0), count: end - buffer.count))
            }
            buffer.replaceSubrange(position..<end, with: data)
            position = end
        }
    }

    func seek(offset: Int64, origin: SeekOrigin) throws -> Int64 {
        try lock.withLock {
            guard !isClosed else { throw StreamError.closed }
            let base: Int64
            switch origin {
            case .begin: base = 0
            case .current: base = Int64(position)
            case .end: base = Int64(buffer.count)
            }
            let (target, overflow) = base.addingReportingOverflow(offset)
            guard !overflow, target >= 0, target <= limit else { throw StreamError.invalidSeek }
            position = Int(target)
            return target
        }
    }

    func flush() throws {}

    func close() throws {
        lock.withLock { isClosed = true }
    }

    func bytes() -> Data {
        lock.withLock { buffer }
    }
}
