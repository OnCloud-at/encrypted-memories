import CryptoKit
import Foundation
import Testing

@testable import PhotosCore

@Suite struct LowercaseHexTests {
    @Test func bytesBecomeLowercaseHexWithTwoDigitsEach() {
        #expect([UInt8]().lowercaseHexString == "")
        #expect([0x00, 0x0f, 0xab, 0xff].lowercaseHexString == "000fabff")
    }

    @Test func everyByteValueMatchesThePaddedLowercaseFormat() {
        let mismatches = (0...255).filter { value in
            let byte = UInt8(value)
            return [byte].lowercaseHexString != String(format: "%02x", byte)
        }
        #expect(mismatches.isEmpty, "bytes that differ from the padded lowercase format: \(mismatches)")
    }

    @Test func aDigestAndAMessageCodeFormatAsKnownVectors() {
        #expect(
            SHA256.hash(data: Data("abc".utf8)).lowercaseHexString
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            Insecure.SHA1.hash(data: Data("abc".utf8)).lowercaseHexString
                == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(Data([0xDE, 0xAD, 0xBE, 0xEF]).lowercaseHexString == "deadbeef")
        #expect(ArraySlice<UInt8>([1, 2, 3, 0xAA]).lowercaseHexString == "010203aa")
    }
}
