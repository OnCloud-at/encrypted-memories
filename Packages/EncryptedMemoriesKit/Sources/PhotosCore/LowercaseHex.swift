import Foundation

private let lowercaseHexDigits = Array("0123456789abcdef".utf8)

extension Sequence where Element == UInt8 {
    /// The bytes as lowercase hexadecimal text with two digits per byte, the form of every digest and identifier
    /// that the app stores or compares. A stray uppercase digit would silently change every stored value.
    public var lowercaseHexString: String {
        var output: [UInt8] = []
        output.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            output.append(lowercaseHexDigits[Int(byte >> 4)])
            output.append(lowercaseHexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
