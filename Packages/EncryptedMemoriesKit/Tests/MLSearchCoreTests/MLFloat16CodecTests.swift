import Foundation
import PhotosCore
import Testing

@testable import MLSearchCore

/// The persisted-row codec must match IEEE-754 binary16 semantics exactly; every decoded
/// value equals what hardware fp16 (CoreML outputs, `Float16`) produces.
@Suite struct MLFloat16CodecTests {
    @Test func decodeEncodesEveryHalfBitPatternLosslessly() {
        // half to float to half is the identity for every non-NaN pattern (each binary16 value
        // is exactly representable in Float32).
        for bits in 0...UInt16.max {
            let value = MLFloat16Codec.float32(fromBits: bits)
            if value.isNaN {
                #expect(MLFloat16Codec.float16Bits(from: value) & 0x7c00 == 0x7c00)
                #expect(MLFloat16Codec.float16Bits(from: value) & 0x03ff != 0)
                continue
            }
            #expect(MLFloat16Codec.float16Bits(from: value) == bits, "bit pattern \(bits)")
        }
    }

    #if arch(arm64)
        @Test func encodeMatchesHardwareFloat16Rounding() {
            // Deterministic pseudo-random sweep, plus targeted edges. Oracle: native Float16
            // conversion (round-to-nearest-even in hardware).
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> Float32 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                // Spread across magnitudes: mantissa-dense values in [-8, 8).
                let unit = Float32(state >> 40) / Float32(1 << 24)
                return (unit - 0.5) * 16
            }
            for _ in 0..<200_000 {
                let value = next()
                #expect(MLFloat16Codec.float16Bits(from: value) == Float16(value).bitPattern, "\(value)")
            }
            let edges: [Float32] = [
                0, -0, 1, -1, 0.1, -0.1, 65504, -65504, 65505, 66000, 1e9, -1e9,
                .infinity, -.infinity,
                5.96e-8, 6.1e-5, 6.097e-5,  // subnormal boundary region
                1e-10, -1e-10,  // below half subnormals to ±0
                2049, 2050, 2051,  // integer rounding beyond 2^11
                0.00006103515625, 0.000061035156,  // smallest normal half
            ]
            for value in edges {
                #expect(MLFloat16Codec.float16Bits(from: value) == Float16(value).bitPattern, "\(value)")
            }
            #expect(MLFloat16Codec.float16Bits(from: .nan) & 0x7c00 == 0x7c00)
            #expect(MLFloat16Codec.float16Bits(from: .nan) & 0x03ff != 0)
        }
    #endif

    @Test func vectorRoundTripQuantizesWithinTolerance() throws {
        let vector = ContiguousArray<Float32>((0..<512).map { Float32($0) / 512 - 0.5 })
        let encoded = MLFloat16Codec.encodeLittleEndian(vector)
        #expect(encoded.count == 512 * MLFloat16Codec.bytesPerElement)
        var block = MLVectorBlock(descriptor: .init(identifier: "fixture", version: 1, embeddingDimension: 512))
        let appended = encoded.withUnsafeBytes {
            block.append(uid: PhotoUID(volumeID: "v", nodeID: "n"), rawLittleEndianFloat16: $0)
        }
        try #require(appended)
        let roundTripped = block.vector(at: 0)
        for (original, stored) in zip(vector, roundTripped) {
            #expect(abs(stored - original) <= max(abs(original) * 0.001, 1e-6))
            #expect(stored == quantizedFloat16(original))
        }
    }

    @Test func decodeRejectsWrongByteCounts() {
        let vector = ContiguousArray<Float32>([1, 2, 3, 4])
        let encoded = MLFloat16Codec.encodeLittleEndian(vector)
        let uid = PhotoUID(volumeID: "v", nodeID: "n")
        for dimension in [5, 3, 4] {
            var block = MLVectorBlock(
                descriptor: .init(identifier: "fixture", version: 1, embeddingDimension: dimension))
            let appended = encoded.withUnsafeBytes { block.append(uid: uid, rawLittleEndianFloat16: $0) }
            #expect(appended == (dimension == 4))
        }
        var block = MLVectorBlock(descriptor: .init(identifier: "fixture", version: 1, embeddingDimension: 1))
        let appended = Data([0x00]).withUnsafeBytes { block.append(uid: uid, rawLittleEndianFloat16: $0) }
        #expect(!appended)
    }
}
