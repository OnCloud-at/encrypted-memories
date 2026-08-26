import Foundation

enum UploadTransportBufferPolicy {
    static let compactBufferSize = 1 * 1_024 * 1_024
    static let highThroughputBufferSize = 4 * 1_024 * 1_024
    static let highThroughputMemoryThreshold: UInt64 = 6 * 1_024 * 1_024 * 1_024

    static func bufferSize(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        physicalMemory >= highThroughputMemoryThreshold ? highThroughputBufferSize : compactBufferSize
    }

    static func makeBoundStreams(bufferSize: Int) throws -> (InputStream, OutputStream, Int) {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(
            withBufferSize: bufferSize,
            inputStream: &input,
            outputStream: &output
        )
        guard let input, let output else {
            throw NSError(
                domain: "EncryptedMemories.UploadTransport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create upload streams"]
            )
        }
        return (input, output, bufferSize)
    }
}
