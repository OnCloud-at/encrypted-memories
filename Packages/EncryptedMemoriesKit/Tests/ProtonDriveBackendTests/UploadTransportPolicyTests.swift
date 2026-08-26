import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ProtonDriveBackend

@Suite("Upload transport policy")
struct UploadTransportPolicyTests {
    @Test func bufferScalesWithAvailableMemory() {
        #expect(
            UploadTransportBufferPolicy.bufferSize(physicalMemory: 4 * 1_024 * 1_024 * 1_024)
                == UploadTransportBufferPolicy.compactBufferSize)
        #expect(
            UploadTransportBufferPolicy.bufferSize(physicalMemory: 6 * 1_024 * 1_024 * 1_024)
                == UploadTransportBufferPolicy.highThroughputBufferSize)
    }

    @Test func boundStreamCreatorUsesRequestedCapacity() throws {
        let (input, output, capacity) = try UploadTransportBufferPolicy.makeBoundStreams(bufferSize: 128 * 1_024)
        #expect(capacity == 128 * 1_024)
        input.close()
        output.close()
    }

    @Test func driveJSONHeadersPreserveSDKValuesAndFillMissingDefaults() {
        var request = URLRequest(url: URL(string: "https://drive-api.proton.me/drive/v2/blocks")!)
        SDKHttpClient.applyDriveJSONHeaders(&request, hasContent: true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.protonmail.v1+json")

        request.setValue("application/custom", forHTTPHeaderField: "Content-Type")
        SDKHttpClient.applyDriveJSONHeaders(&request, hasContent: true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/custom")
    }

    @Test func generatedJPEGsRespectProtonLimitsAndHaveNoAlpha() async throws {
        let image = try deterministicNoiseImage(width: 2_048, height: 1_536)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-thumbnail-policy-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let thumbnails = await UploadMediaProcessor.thumbnails(for: url, isVideo: false)
        #expect(thumbnails.count == 2)
        #expect(thumbnails[0].data.count <= UploadMediaProcessor.thumbnailMaxBytes)
        #expect(thumbnails[1].data.count <= UploadMediaProcessor.previewMaxBytes)
        for thumbnail in thumbnails {
            let source = try #require(CGImageSourceCreateWithData(thumbnail.data as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo))
        }
    }

    private func deterministicNoiseImage(width: Int, height: Int) throws -> CGImage {
        var pixels = Data(count: width * height * 4)
        let byteCount = pixels.count
        pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            var state: UInt32 = 0x1234_5678
            for index in stride(from: 0, to: byteCount, by: 4) {
                state = state &* 1_664_525 &+ 1_013_904_223
                base[index] = UInt8(truncatingIfNeeded: state >> 16)
                base[index + 1] = UInt8(truncatingIfNeeded: state >> 8)
                base[index + 2] = UInt8(truncatingIfNeeded: state)
                base[index + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        return try #require(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            ))
    }
}
