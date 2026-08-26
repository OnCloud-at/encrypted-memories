import Foundation
import Testing

@testable import MLSearchAppleAdapter
@testable import MLSearchCore

@Suite struct AppleVisionCapabilityProviderTests {
    @Test func inventoryIsCompleteUniqueAndActionable() {
        let entries = AppleVisionCapabilityInventory.entries

        #expect(Set(entries.map(\.kind)).count == entries.count)
        #expect(Set(entries.map(\.kind)) == Set(MLNativeAnalysisKind.allCases))
        for entry in entries {
            #expect(!entry.swiftRequestName.isEmpty)
            #expect(!entry.minimumIOS.isEmpty)
            #expect(!entry.minimumMacOS.isEmpty)
            #expect(!entry.productConsumers.isEmpty)
            #expect(!entry.fallback.isEmpty)
            #expect(!entry.dataContract.outputContract.isEmpty)
            #expect(!entry.dataContract.confidenceContract.isEmpty)
            #expect(!entry.dataContract.revisionCompatibility.isEmpty)
            #expect(!entry.measurement.corpusIdentifier.isEmpty)
            #expect(!entry.measurement.passGate.isEmpty)
        }

        let indexedEntries = entries.filter { $0.executionMode == .indexed }
        #expect(indexedEntries.count == 16)
        #expect(indexedEntries.allSatisfy { $0.dataContract.persistence == .revisionScopedDerived })
        let nonIndexedEntries = entries.filter { $0.executionMode != .indexed }
        #expect(nonIndexedEntries.allSatisfy { $0.dataContract.persistence == .never })
        #expect(entries.contains { $0.executionMode == .onDemand })
        #expect(entries.contains { $0.executionMode == .temporalOrPairwise })

        let exclusions = AppleVisionCapabilityInventory.exclusions
        #expect(Set(exclusions.map(\.requestName)).count == exclusions.count)
        #expect(
            exclusions == [
                AppleVisionRequestExclusion(
                    requestName: "CoreMLRequest",
                    reason:
                        "Custom model transport, not a built-in Vision analysis. Encrypted Memories keeps exact model preprocessing and tensor contracts in the existing Core ML runtime."
                )
            ])
        #expect(
            entries.contains {
                $0.kind == .pairwiseOpticalFlow
                    && $0.swiftRequestName == "VNGenerateOpticalFlowRequest"
                    && $0.executionMode == .temporalOrPairwise
            })
        let wholeLibraryKinds = Set(indexedEntries.map(\.kind))
        #expect(
            wholeLibraryKinds.isSuperset(of: [
                .textRecognition,
                .documentRecognition,
                .barcodeDetection,
                .imageClassification,
                .animalRecognition,
                .humanDetection,
                .imageFeaturePrint,
                .faceDetection,
                .faceLandmarks,
                .faceCaptureQuality,
                .imageAesthetics,
                .objectnessSaliency,
                .lensSmudgeDetection,
                .horizon,
            ]))
        #expect(
            wholeLibraryKinds.isDisjoint(with: [
                .animalBodyPose,
                .foregroundInstanceMask,
                .personInstanceMask,
                .personSegmentation,
                .attentionSaliency,
                .humanBodyPose,
                .humanHandPose,
                .humanBodyPose3D,
                .contours,
                .rectangles,
            ]))
    }

    @Test func liveProbeReportsExplicitSupportedRevisionContracts() async {
        let snapshot = await AppleVisionCapabilityProvider().capabilitySnapshot()

        #expect(snapshot.providerIdentifier == AppleVisionCapabilityProvider.providerIdentifier)
        #expect(snapshot.sdkIdentifier.hasPrefix("Vision SDK "))
        #expect(Set(snapshot.capabilities.map(\.kind)) == Set(MLNativeAnalysisKind.allCases))
        for capability in snapshot.capabilities where capability.isAvailable {
            #expect(capability.selectedRevision != nil)
            #expect(capability.selectedRevision.map(capability.supportedRevisions.contains) == true)
            #expect(capability.executionMode != .unsupported)
        }

        let text = snapshot.capability(for: .textRecognition)
        guard text?.isAvailable == true else {
            #expect(
                text?.availability == .unavailable(.runtime)
                    || text?.availability == .unavailable(.hardware)
                    || text?.availability == .unavailable(.probeFailed)
            )
            return
        }
        #expect(text?.isAvailable == true)
        #expect(text?.supportedLanguages.isEmpty == false)

        let classification = snapshot.capability(for: .imageClassification)
        #expect(classification?.supportedIdentifiers.isEmpty == false)

        let animals = snapshot.capability(for: .animalRecognition)
        let supportedAnimals = Set(animals?.supportedAnimals ?? [])
        #expect(supportedAnimals.isSuperset(of: ["cat", "dog"]))

        let barcodes = snapshot.capability(for: .barcodeDetection)
        if barcodes?.isAvailable == true {
            #expect(barcodes?.supportedSymbologies.isEmpty == false)
        } else {
            #expect(barcodes?.selectedRevision == nil)
            #expect(barcodes?.availability == .unavailable(.runtime))
        }

        for kind in [
            MLNativeAnalysisKind.humanBodyPose,
            .humanHandPose,
            .contours,
            .horizon,
            .rectangles,
            .textRectangles,
        ] {
            let capability = snapshot.capability(for: kind)
            guard capability?.isAvailable == true else {
                #expect(
                    capability?.availability == .unavailable(.runtime)
                        || capability?.availability == .unavailable(.hardware)
                        || capability?.availability == .unavailable(.probeFailed)
                )
                continue
            }
            if #available(macOS 14.0, iOS 17.0, *) {
                #expect(capability?.computeSupport.isEmpty == false)
            }
        }
    }

    @Test func probeRunsAwayFromTheCallingActor() async {
        let provider = AppleVisionCapabilityProvider {
            #expect(!Thread.isMainThread)
            return MLNativeAnalysisCapabilitySnapshot(
                providerIdentifier: AppleVisionCapabilityProvider.providerIdentifier,
                sdkIdentifier: "fixture",
                capabilities: []
            )
        }

        _ = await provider.capabilitySnapshot()
    }

    @Test func runtimeRevisionProbeFallsBackFromBrokenNewestRevision() async {
        let probe = OperationalRevisionProbe(successfulRevision: 3)

        let selected = await AppleVisionRuntimeSupport.firstOperationalRevision(
            from: [2, 4, 3, 1]
        ) { revision in
            await probe.isOperational(revision)
        }

        #expect(selected == 3)
        #expect(await probe.visitedRevisions == [4, 3])
    }

    @Test func missingHardwareRemainsTypedAndDoesNotRequireDeviceLists() async {
        let provider = AppleVisionCapabilityProvider {
            MLNativeAnalysisCapabilitySnapshot(
                providerIdentifier: AppleVisionCapabilityProvider.providerIdentifier,
                sdkIdentifier: "fixture",
                capabilities: [
                    MLNativeAnalysisCapability(
                        kind: .lensSmudgeDetection,
                        implementationIdentifier: "apple.vision.detect-lens-smudge",
                        availability: .unavailable(.hardware),
                        selectedRevision: nil,
                        supportedRevisions: []
                    )
                ]
            )
        }

        let capability = await provider.capabilitySnapshot().capability(for: .lensSmudgeDetection)
        #expect(capability?.availability == .unavailable(.hardware))
    }
}

private actor OperationalRevisionProbe {
    let successfulRevision: Int
    private(set) var visitedRevisions: [Int] = []

    init(successfulRevision: Int) {
        self.successfulRevision = successfulRevision
    }

    func isOperational(_ revision: Int) -> Bool {
        visitedRevisions.append(revision)
        return revision == successfulRevision
    }
}
