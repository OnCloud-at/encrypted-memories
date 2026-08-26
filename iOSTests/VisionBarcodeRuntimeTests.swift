import CoreGraphics
import MLSearchCore
import PhotosCore
import Testing
@preconcurrency import Vision

@testable import MLSearchAppleAdapter

@Suite struct VisionBarcodeRuntimeTests {
    @Test func simulatorSchedulesBarcodeDetectionOnlyWhenTheRuntimeExecutesIt() async throws {
        #if targetEnvironment(simulator)
            let operationalRevision =
                await AppleVisionRuntimeSupport
                .barcodeDetectionRevisionIdentifier()
            let snapshot = await AppleVisionCapabilityProvider().capabilitySnapshot()
            let barcodeCapability = try #require(snapshot.capability(for: .barcodeDetection))
            #expect(barcodeCapability.isAvailable == (operationalRevision != nil))
            #expect(barcodeCapability.selectedRevision == operationalRevision)

            let configuration = try MLNativeSearchConfiguration(
                accountIdentifier: "simulator-runtime-test",
                capabilitySnapshot: snapshot
            )
            let scheduledBarcodeRevision = configuration.executionKey.artifacts.compactMap { artifact -> String? in
                guard case .native(_, let kind, let revision) = artifact.producer,
                    kind == .barcodeDetection
                else { return nil }
                return revision
            }.first
            #expect((scheduledBarcodeRevision != nil) == (operationalRevision != nil))
            #expect(scheduledBarcodeRevision == operationalRevision)

            let context = try #require(
                CGContext(
                    data: nil,
                    width: 256,
                    height: 256,
                    bitsPerComponent: 8,
                    bytesPerRow: 256 * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
            let image = try #require(context.makeImage())
            let revisionIdentifier: String
            if let operationalRevision {
                revisionIdentifier = operationalRevision
            } else {
                revisionIdentifier = String(
                    describing: try #require(DetectBarcodesRequest.supportedRevisions.first)
                )
            }
            let asset = try MLPipelineAssetRevision(
                uid: PhotoUID(volumeID: "volume", nodeID: "photo"),
                sourceRevision: "photo"
            )
            let artifact = try MLDerivedArtifactIdentity(
                pipelineID: .nativeSearch,
                stageID: MLStageID(rawValue: "barcode-payload"),
                producer: .native(
                    providerIdentifier: AppleVisionCapabilityProvider.providerIdentifier,
                    kind: .barcodeDetection,
                    requestRevision: revisionIdentifier
                ),
                preprocessingRevision: MLNativeSearchConfiguration.preprocessingRevision,
                output: .barcodePayload,
                schemaEpoch: 1
            )
            let executor = AppleVisionPipelineExecutor(
                imageSource: SimulatorBarcodeImageSource(image: image)
            )
            let result = try #require(
                await executor.execute(
                    try MLAssetAnalysisPlan(
                        asset: asset,
                        workItems: [MLDerivedPipelineWorkItem(asset: asset, artifact: artifact)]
                    )
                ).first)
            if operationalRevision != nil {
                #expect(result.outcome == .completedEmpty)
            } else {
                #expect(result.outcome == .skipped(.unsupportedCapability))
            }

            let staleRevisionIdentifier =
                DetectBarcodesRequest.supportedRevisions
                .map { String(describing: $0) }
                .first { $0 != operationalRevision } ?? "known-stale-revision"
            let staleArtifact = try MLDerivedArtifactIdentity(
                pipelineID: .nativeSearch,
                stageID: MLStageID(rawValue: "stale-barcode-payload"),
                producer: .native(
                    providerIdentifier: AppleVisionCapabilityProvider.providerIdentifier,
                    kind: .barcodeDetection,
                    requestRevision: staleRevisionIdentifier
                ),
                preprocessingRevision: MLNativeSearchConfiguration.preprocessingRevision,
                output: .barcodePayload,
                schemaEpoch: 1
            )
            let staleResult = try #require(
                await executor.execute(
                    try MLAssetAnalysisPlan(
                        asset: asset,
                        workItems: [MLDerivedPipelineWorkItem(asset: asset, artifact: staleArtifact)]
                    )
                ).first)
            #expect(staleResult.outcome == .skipped(.unsupportedCapability))
        #endif
    }
}

private struct SimulatorBarcodeImageSource: CoreMLImageSource {
    let image: CGImage

    func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome {
        .image(CoreMLSourceImage(cgImage: image))
    }
}
