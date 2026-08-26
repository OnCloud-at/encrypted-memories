import CoreGraphics
@preconcurrency import CoreML
import Foundation
import MLSearchCore
@preconcurrency import Vision

/// Discovers the Vision surface exposed by the current OS and hardware without device-name tables.
/// Introspection can be expensive, so the probe always runs on a detached utility task.
public struct AppleVisionCapabilityProvider: MLNativeAnalysisCapabilityProvider {
    public static let providerIdentifier = "apple.vision"

    private let probe: @Sendable () async -> MLNativeAnalysisCapabilitySnapshot

    public init() {
        self.probe = { await AppleVisionCapabilityProbe.snapshot() }
    }

    init(probe: @escaping @Sendable () -> MLNativeAnalysisCapabilitySnapshot) {
        self.probe = { probe() }
    }

    public func capabilitySnapshot() async -> MLNativeAnalysisCapabilitySnapshot {
        let probe = self.probe
        return await Task.detached(priority: .utility) { await probe() }.value
    }
}

enum AppleVisionRuntimeSupport {
    /// Runtime revision metadata is necessary but not sufficient: some OS/runtime and hardware
    /// combinations advertise a barcode revision but cannot create its inference context. Execute
    /// the concrete request once per process so future runtimes and real devices qualify themselves.
    private static let barcodeDetectionProbe = Task.detached(priority: .utility) {
        await probeBarcodeDetectionRevision()
    }

    static func barcodeDetectionRevisionIdentifier() async -> String? {
        await barcodeDetectionProbe.value
    }

    static func firstOperationalRevision<Revision: Comparable>(
        from revisions: [Revision],
        probe: (Revision) async -> Bool
    ) async -> Revision? {
        for revision in revisions.sorted(by: >) {
            if await probe(revision) { return revision }
        }
        return nil
    }

    private static func probeBarcodeDetectionRevision() async -> String? {
        guard let image = probeImage() else { return nil }

        if #available(macOS 15.0, iOS 18.0, *) {
            let revision = await firstOperationalRevision(
                from: DetectBarcodesRequest.supportedRevisions
            ) { revision in
                var request = DetectBarcodesRequest(revision)
                let symbologies = request.supportedSymbologies
                guard !symbologies.isEmpty else { return false }
                request.symbologies = symbologies
                do {
                    _ = try await request.perform(on: image, orientation: .up)
                    return true
                } catch {
                    return false
                }
            }
            return revision.map { String(describing: $0) }
        }

        let revision = await firstOperationalRevision(
            from: Array(VNDetectBarcodesRequest.supportedRevisions)
        ) { revision in
            let request = VNDetectBarcodesRequest()
            request.revision = revision
            guard let symbologies = try? request.supportedSymbologies(), !symbologies.isEmpty else {
                return false
            }
            request.symbologies = symbologies
            request.preferBackgroundProcessing = true
            do {
                try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
                return true
            } catch {
                return false
            }
        }
        return revision.map { "revision\($0)" }
    }

    private static func probeImage() -> CGImage? {
        let width = 256
        let height = 256
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

private enum AppleVisionCapabilityProbe {
    private static let snapshotTask = Task.detached(priority: .utility) {
        await makeSnapshot()
    }

    static func snapshot() async -> MLNativeAnalysisCapabilitySnapshot {
        await snapshotTask.value
    }

    #if compiler(>=6.4)
        private static let sdkIdentifier = "Vision SDK 27.0"
    #else
        private static let sdkIdentifier = "Vision SDK 26.5"
    #endif

    private static func makeSnapshot() async -> MLNativeAnalysisCapabilitySnapshot {
        let barcodeDetectionRevision =
            await AppleVisionRuntimeSupport
            .barcodeDetectionRevisionIdentifier()
        var capabilities: [MLNativeAnalysisCapability]
        if #available(macOS 15.0, iOS 18.0, *) {
            capabilities = modernBaseCapabilities(barcodeDetectionRevision: barcodeDetectionRevision)
        } else {
            capabilities = legacyBaseCapabilities(barcodeDetectionRevision: barcodeDetectionRevision)
        }

        if #available(macOS 26.0, iOS 26.0, *) {
            capabilities.append(structuredDocumentCapability())
            capabilities.append(lensSmudgeCapability())
        } else {
            capabilities.append(unavailable(.documentRecognition, reason: .operatingSystem))
            capabilities.append(unavailable(.lensSmudgeDetection, reason: .operatingSystem))
        }

        if #available(macOS 15.0, iOS 18.0, *) {
            capabilities.append(imageAestheticsCapability())
        } else {
            capabilities.append(unavailable(.imageAesthetics, reason: .operatingSystem))
        }

        #if compiler(>=6.4)
            if #available(macOS 27.0, iOS 27.0, *) {
                capabilities.append(iterativeSegmentationCapability())
            } else {
                capabilities.append(unavailable(.iterativeSegmentation, reason: .operatingSystem))
            }
        #else
            capabilities.append(unavailable(.iterativeSegmentation, reason: .operatingSystem))
        #endif

        let byKind = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.kind, $0) })
        let ordered = AppleVisionCapabilityInventory.entries.map { entry in
            byKind[entry.kind] ?? unavailable(entry.kind, reason: .operatingSystem)
        }
        return MLNativeAnalysisCapabilitySnapshot(
            providerIdentifier: AppleVisionCapabilityProvider.providerIdentifier,
            sdkIdentifier: sdkIdentifier,
            capabilities: ordered
        )
    }

    private static func legacyBaseCapabilities(
        barcodeDetectionRevision: String?
    ) -> [MLNativeAnalysisCapability] {
        let textRequest = VNRecognizeTextRequest()
        let barcodeRequest = VNDetectBarcodesRequest()
        let classificationRequest = VNClassifyImageRequest()
        let animalRequest = VNRecognizeAnimalsRequest()

        var capabilities: [MLNativeAnalysisCapability] = [
            legacyCapability(
                .textRecognition,
                request: textRequest,
                supportedLanguages: (try? textRequest.supportedRecognitionLanguages()) ?? []
            ),
            legacyBarcodeCapability(
                barcodeRequest,
                selectedRevisionIdentifier: barcodeDetectionRevision
            ),
            legacyCapability(.documentSegmentation, request: VNDetectDocumentSegmentationRequest()),
            legacyCapability(
                .imageClassification,
                request: classificationRequest,
                supportedIdentifiers: (try? classificationRequest.supportedIdentifiers()) ?? []
            ),
            legacyCapability(
                .animalRecognition,
                request: animalRequest,
                supportedAnimals: ((try? animalRequest.supportedIdentifiers()) ?? [])
                    .map { $0.rawValue.lowercased() }
            ),
            legacyCapability(.humanDetection, request: VNDetectHumanRectanglesRequest()),
            legacyCapability(.imageFeaturePrint, request: VNGenerateImageFeaturePrintRequest()),
            legacyCapability(.faceDetection, request: VNDetectFaceRectanglesRequest()),
            legacyCapability(.faceLandmarks, request: VNDetectFaceLandmarksRequest()),
            legacyCapability(.faceCaptureQuality, request: VNDetectFaceCaptureQualityRequest()),
            legacyCapability(.personSegmentation, request: VNGeneratePersonSegmentationRequest()),
            legacyCapability(.attentionSaliency, request: VNGenerateAttentionBasedSaliencyImageRequest()),
            legacyCapability(.objectnessSaliency, request: VNGenerateObjectnessBasedSaliencyImageRequest()),
            legacyCapability(.humanBodyPose, request: VNDetectHumanBodyPoseRequest()),
            legacyCapability(.humanHandPose, request: VNDetectHumanHandPoseRequest()),
            legacyCapability(.contours, request: VNDetectContoursRequest()),
            legacyCapability(.horizon, request: VNDetectHorizonRequest()),
            legacyCapability(.rectangles, request: VNDetectRectanglesRequest()),
            legacyCapability(.textRectangles, request: VNDetectTextRectanglesRequest()),
            legacyRevisionOnly(.trajectories, requestType: VNDetectTrajectoriesRequest.self),
            legacyRevisionOnly(.pairwiseOpticalFlow, requestType: VNGenerateOpticalFlowRequest.self),
            legacyRevisionOnly(.objectTracking, requestType: VNTrackObjectRequest.self),
            legacyRevisionOnly(.rectangleTracking, requestType: VNTrackRectangleRequest.self),
            legacyRevisionOnly(
                .translationalImageRegistration,
                requestType: VNTranslationalImageRegistrationRequest.self
            ),
            legacyRevisionOnly(
                .homographicImageRegistration,
                requestType: VNHomographicImageRegistrationRequest.self
            ),
        ]

        if #available(macOS 14.0, iOS 17.0, *) {
            capabilities.append(legacyCapability(.animalBodyPose, request: VNDetectAnimalBodyPoseRequest()))
            capabilities.append(
                legacyCapability(.foregroundInstanceMask, request: VNGenerateForegroundInstanceMaskRequest()))
            capabilities.append(legacyCapability(.personInstanceMask, request: VNGeneratePersonInstanceMaskRequest()))
            capabilities.append(legacyCapability(.humanBodyPose3D, request: VNDetectHumanBodyPose3DRequest()))
            capabilities.append(legacyCapability(.opticalFlow, request: VNTrackOpticalFlowRequest()))
        } else {
            capabilities.append(unavailable(.animalBodyPose, reason: .operatingSystem))
            capabilities.append(unavailable(.foregroundInstanceMask, reason: .operatingSystem))
            capabilities.append(unavailable(.personInstanceMask, reason: .operatingSystem))
            capabilities.append(unavailable(.humanBodyPose3D, reason: .operatingSystem))
            capabilities.append(unavailable(.opticalFlow, reason: .operatingSystem))
        }

        return capabilities
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func modernBaseCapabilities(
        barcodeDetectionRevision: String?
    ) -> [MLNativeAnalysisCapability] {
        [
            selectedModernCapability(
                .textRecognition,
                revisions: RecognizeTextRequest.supportedRevisions,
                request: RecognizeTextRequest.init,
                supportedLanguages: {
                    $0.supportedRecognitionLanguages.map(\.minimalIdentifier)
                }
            ),
            modernBarcodeCapability(selectedRevisionIdentifier: barcodeDetectionRevision),
            selectedModernCapability(
                .documentSegmentation,
                revisions: DetectDocumentSegmentationRequest.supportedRevisions,
                request: DetectDocumentSegmentationRequest.init
            ),
            selectedModernCapability(
                .imageClassification,
                revisions: ClassifyImageRequest.supportedRevisions,
                request: ClassifyImageRequest.init,
                supportedIdentifiers: \.supportedIdentifiers
            ),
            selectedModernCapability(
                .animalRecognition,
                revisions: RecognizeAnimalsRequest.supportedRevisions,
                request: RecognizeAnimalsRequest.init,
                supportedAnimals: { _ in ["cat", "dog"] }
            ),
            selectedModernCapability(
                .humanDetection,
                revisions: DetectHumanRectanglesRequest.supportedRevisions,
                request: DetectHumanRectanglesRequest.init
            ),
            selectedModernCapability(
                .imageFeaturePrint,
                revisions: GenerateImageFeaturePrintRequest.supportedRevisions,
                request: GenerateImageFeaturePrintRequest.init
            ),
            selectedModernCapability(
                .faceDetection,
                revisions: DetectFaceRectanglesRequest.supportedRevisions,
                request: DetectFaceRectanglesRequest.init
            ),
            selectedModernCapability(
                .faceLandmarks,
                revisions: DetectFaceLandmarksRequest.supportedRevisions,
                request: DetectFaceLandmarksRequest.init
            ),
            selectedModernCapability(
                .faceCaptureQuality,
                revisions: DetectFaceCaptureQualityRequest.supportedRevisions,
                request: DetectFaceCaptureQualityRequest.init
            ),
            selectedModernCapability(
                .personSegmentation,
                revisions: GeneratePersonSegmentationRequest.supportedRevisions,
                request: { GeneratePersonSegmentationRequest($0) }
            ),
            selectedModernCapability(
                .attentionSaliency,
                revisions: GenerateAttentionBasedSaliencyImageRequest.supportedRevisions,
                request: GenerateAttentionBasedSaliencyImageRequest.init
            ),
            selectedModernCapability(
                .objectnessSaliency,
                revisions: GenerateObjectnessBasedSaliencyImageRequest.supportedRevisions,
                request: GenerateObjectnessBasedSaliencyImageRequest.init
            ),
            selectedModernCapability(
                .humanBodyPose,
                revisions: DetectHumanBodyPoseRequest.supportedRevisions,
                request: DetectHumanBodyPoseRequest.init,
                supportedIdentifiers: {
                    $0.supportedJointNames.map { "joint:\(String(describing: $0))" }
                        + $0.supportedJointsGroupNames.map { "group:\(String(describing: $0))" }
                }
            ),
            selectedModernCapability(
                .humanHandPose,
                revisions: DetectHumanHandPoseRequest.supportedRevisions,
                request: DetectHumanHandPoseRequest.init,
                supportedIdentifiers: {
                    $0.supportedJointNames.map { "joint:\(String(describing: $0))" }
                        + ((try? $0.supportedJointsGroupNames) ?? [])
                        .map { "group:\(String(describing: $0))" }
                }
            ),
            selectedModernCapability(
                .contours,
                revisions: DetectContoursRequest.supportedRevisions,
                request: DetectContoursRequest.init
            ),
            selectedModernCapability(
                .horizon,
                revisions: DetectHorizonRequest.supportedRevisions,
                request: DetectHorizonRequest.init
            ),
            selectedModernCapability(
                .rectangles,
                revisions: DetectRectanglesRequest.supportedRevisions,
                request: DetectRectanglesRequest.init
            ),
            selectedModernCapability(
                .textRectangles,
                revisions: DetectTextRectanglesRequest.supportedRevisions,
                request: DetectTextRectanglesRequest.init
            ),
            modernRevisionOnly(
                .trajectories,
                revisions: DetectTrajectoriesRequest.supportedRevisions
            ),
            legacyRevisionOnly(.pairwiseOpticalFlow, requestType: VNGenerateOpticalFlowRequest.self),
            selectedModernCapability(
                .opticalFlow,
                revisions: TrackOpticalFlowRequest.supportedRevisions,
                request: { TrackOpticalFlowRequest($0) }
            ),
            modernRevisionOnly(
                .objectTracking,
                revisions: TrackObjectRequest.supportedRevisions
            ),
            modernRevisionOnly(
                .rectangleTracking,
                revisions: TrackRectangleRequest.supportedRevisions
            ),
            modernRevisionOnly(
                .translationalImageRegistration,
                revisions: TrackTranslationalImageRegistrationRequest.supportedRevisions
            ),
            modernRevisionOnly(
                .homographicImageRegistration,
                revisions: TrackHomographicImageRegistrationRequest.supportedRevisions
            ),
            selectedModernCapability(
                .animalBodyPose,
                revisions: DetectAnimalBodyPoseRequest.supportedRevisions,
                request: DetectAnimalBodyPoseRequest.init,
                supportedIdentifiers: {
                    $0.supportedJointNames.map { "joint:\(String(describing: $0))" }
                        + $0.supportedJointsGroupNames.map { "group:\(String(describing: $0))" }
                }
            ),
            selectedModernCapability(
                .foregroundInstanceMask,
                revisions: GenerateForegroundInstanceMaskRequest.supportedRevisions,
                request: GenerateForegroundInstanceMaskRequest.init
            ),
            selectedModernCapability(
                .personInstanceMask,
                revisions: GeneratePersonInstanceMaskRequest.supportedRevisions,
                request: GeneratePersonInstanceMaskRequest.init
            ),
            selectedModernCapability(
                .humanBodyPose3D,
                revisions: DetectHumanBodyPose3DRequest.supportedRevisions,
                request: { DetectHumanBodyPose3DRequest($0) },
                supportedIdentifiers: {
                    $0.supportedJointNames.map { "joint:\(String(describing: $0))" }
                        + $0.supportedJointsGroupNames.map { "group:\(String(describing: $0))" }
                }
            ),
        ]
    }

    private static func legacyBarcodeCapability(
        _ request: VNDetectBarcodesRequest,
        selectedRevisionIdentifier: String?
    ) -> MLNativeAnalysisCapability {
        let requestType = type(of: request)
        guard let selectedRevisionIdentifier,
            let selectedRevision = requestType.supportedRevisions.first(where: {
                "revision\($0)" == selectedRevisionIdentifier
            })
        else {
            return unavailable(.barcodeDetection, reason: .runtime)
        }
        request.revision = selectedRevision
        return MLNativeAnalysisCapability(
            kind: .barcodeDetection,
            implementationIdentifier: implementationIdentifier(for: .barcodeDetection),
            executionMode: executionMode(for: .barcodeDetection),
            availability: .available,
            selectedRevision: selectedRevisionIdentifier,
            supportedRevisions: requestType.supportedRevisions.map { "revision\($0)" },
            supportedSymbologies: ((try? request.supportedSymbologies()) ?? [])
                .map(\.rawValue)
                .sorted(),
            computeSupport: legacyComputeSupport(for: request)
        )
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func modernBarcodeCapability(
        selectedRevisionIdentifier: String?
    ) -> MLNativeAnalysisCapability {
        let supportedRevisions = DetectBarcodesRequest.supportedRevisions
        guard let selectedRevisionIdentifier,
            let selectedRevision = supportedRevisions.first(where: {
                String(describing: $0) == selectedRevisionIdentifier
            })
        else {
            return unavailable(.barcodeDetection, reason: .runtime)
        }
        let request = DetectBarcodesRequest(selectedRevision)
        return modernCapability(
            .barcodeDetection,
            request: request,
            selectedRevision: selectedRevision,
            supportedRevisions: supportedRevisions,
            supportedSymbologies: request.supportedSymbologies.map { String(describing: $0) }
        )
    }

    private static func legacyCapability(
        _ kind: MLNativeAnalysisKind,
        request: VNRequest,
        supportedLanguages: [String] = [],
        supportedIdentifiers: [String] = [],
        supportedAnimals: [String] = [],
        supportedSymbologies: [String] = []
    ) -> MLNativeAnalysisCapability {
        let requestType = type(of: request)
        let revisions = requestType.supportedRevisions.map { "revision\($0)" }
        guard !revisions.isEmpty else { return unavailable(kind, reason: .runtime) }
        let selected = "revision\(requestType.defaultRevision)"
        return MLNativeAnalysisCapability(
            kind: kind,
            implementationIdentifier: implementationIdentifier(for: kind),
            executionMode: executionMode(for: kind),
            availability: .available,
            selectedRevision: selected,
            supportedRevisions: revisions,
            supportedLanguages: supportedLanguages.sorted(),
            supportedIdentifiers: supportedIdentifiers.sorted(),
            supportedAnimals: supportedAnimals.sorted(),
            supportedSymbologies: supportedSymbologies.sorted(),
            computeSupport: legacyComputeSupport(for: request)
        )
    }

    private static func legacyRevisionOnly(
        _ kind: MLNativeAnalysisKind,
        requestType: VNRequest.Type
    ) -> MLNativeAnalysisCapability {
        let revisions = requestType.supportedRevisions.map { "revision\($0)" }
        guard !revisions.isEmpty else { return unavailable(kind, reason: .runtime) }
        return MLNativeAnalysisCapability(
            kind: kind,
            implementationIdentifier: implementationIdentifier(for: kind),
            executionMode: executionMode(for: kind),
            availability: .available,
            selectedRevision: "revision\(requestType.defaultRevision)",
            supportedRevisions: revisions
        )
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func selectedModernCapability<Request: VisionRequest, Revision: Comparable>(
        _ kind: MLNativeAnalysisKind,
        revisions: [Revision],
        request: (Revision?) -> Request,
        supportedLanguages: (Request) -> [String] = { _ in [] },
        supportedIdentifiers: (Request) -> [String] = { _ in [] },
        supportedAnimals: (Request) -> [String] = { _ in [] },
        supportedSymbologies: (Request) -> [String] = { _ in [] }
    ) -> MLNativeAnalysisCapability {
        guard let selected = revisions.max() else {
            return unavailable(kind, reason: .runtime)
        }
        let request = request(selected)
        return modernCapability(
            kind,
            request: request,
            selectedRevision: selected,
            supportedRevisions: revisions,
            supportedLanguages: supportedLanguages(request),
            supportedIdentifiers: supportedIdentifiers(request),
            supportedAnimals: supportedAnimals(request),
            supportedSymbologies: supportedSymbologies(request)
        )
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func modernRevisionOnly<Revision: Comparable>(
        _ kind: MLNativeAnalysisKind,
        revisions: [Revision]
    ) -> MLNativeAnalysisCapability {
        guard let selected = revisions.max() else {
            return unavailable(kind, reason: .runtime)
        }
        return MLNativeAnalysisCapability(
            kind: kind,
            implementationIdentifier: implementationIdentifier(for: kind),
            executionMode: executionMode(for: kind),
            availability: .available,
            selectedRevision: String(describing: selected),
            supportedRevisions: revisions.map { String(describing: $0) }
        )
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func structuredDocumentCapability() -> MLNativeAnalysisCapability {
        let revisions = RecognizeDocumentsRequest.supportedRevisions
        guard let selected = revisions.max() else {
            return unavailable(.documentRecognition, reason: .runtime)
        }
        let request = RecognizeDocumentsRequest(selected)
        return modernCapability(
            .documentRecognition,
            request: request,
            selectedRevision: selected,
            supportedRevisions: revisions,
            supportedLanguages: request.supportedRecognitionLanguages.map(\.minimalIdentifier),
            supportedSymbologies: request.supportedBarcodeSymbologies.map { String(describing: $0) }
        )
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func lensSmudgeCapability() -> MLNativeAnalysisCapability {
        let revisions = DetectLensSmudgeRequest.supportedRevisions
        guard let selected = revisions.max() else {
            return unavailable(.lensSmudgeDetection, reason: .hardware)
        }
        return modernCapability(
            .lensSmudgeDetection,
            request: DetectLensSmudgeRequest(selected),
            selectedRevision: selected,
            supportedRevisions: revisions
        )
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func imageAestheticsCapability() -> MLNativeAnalysisCapability {
        let revisions = CalculateImageAestheticsScoresRequest.supportedRevisions
        guard let selected = revisions.max() else {
            return unavailable(.imageAesthetics, reason: .runtime)
        }
        return modernCapability(
            .imageAesthetics,
            request: CalculateImageAestheticsScoresRequest(selected),
            selectedRevision: selected,
            supportedRevisions: revisions
        )
    }

    #if compiler(>=6.4)
        @available(macOS 27.0, iOS 27.0, *)
        private static func iterativeSegmentationCapability() -> MLNativeAnalysisCapability {
            let revisions = GenerateIterativeSegmentationRequest.supportedRevisions
            guard let selected = revisions.max() else {
                return unavailable(.iterativeSegmentation, reason: .runtime)
            }
            let request = GenerateIterativeSegmentationRequest(
                seedPoint: NormalizedPoint(x: 0.5, y: 0.5),
                selected
            )
            return modernCapability(
                .iterativeSegmentation,
                request: request,
                selectedRevision: selected,
                supportedRevisions: revisions
            )
        }
    #endif

    @available(macOS 15.0, iOS 18.0, *)
    private static func modernCapability<Request: VisionRequest, Revision>(
        _ kind: MLNativeAnalysisKind,
        request: Request,
        selectedRevision: Revision,
        supportedRevisions: [Revision],
        supportedLanguages: [String] = [],
        supportedIdentifiers: [String] = [],
        supportedAnimals: [String] = [],
        supportedSymbologies: [String] = []
    ) -> MLNativeAnalysisCapability {
        MLNativeAnalysisCapability(
            kind: kind,
            implementationIdentifier: implementationIdentifier(for: kind),
            executionMode: executionMode(for: kind),
            availability: .available,
            selectedRevision: String(describing: selectedRevision),
            supportedRevisions: supportedRevisions.map { String(describing: $0) },
            supportedLanguages: supportedLanguages.sorted(),
            supportedIdentifiers: supportedIdentifiers.sorted(),
            supportedAnimals: supportedAnimals.sorted(),
            supportedSymbologies: supportedSymbologies.sorted(),
            computeSupport: modernComputeSupport(for: request)
        )
    }

    private static func legacyComputeSupport(for request: VNRequest) -> [MLNativeAnalysisComputeSupport] {
        guard #available(macOS 14.0, iOS 17.0, *),
            let devicesByStage = try? request.supportedComputeStageDevices
        else { return [] }
        return devicesByStage.map { stage, devices in
            MLNativeAnalysisComputeSupport(
                stage: map(stage),
                devices: uniqueDevices(devices.map(map))
            )
        }
        .sorted { $0.stage.rawValue < $1.stage.rawValue }
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func modernComputeSupport<Request: VisionRequest>(
        for request: Request
    ) -> [MLNativeAnalysisComputeSupport] {
        request.supportedComputeStageDevices.map { stage, devices in
            MLNativeAnalysisComputeSupport(
                stage: map(stage),
                devices: uniqueDevices(devices.map(map))
            )
        }
        .sorted { $0.stage.rawValue < $1.stage.rawValue }
    }

    private static func map(_ stage: VNComputeStage) -> MLNativeAnalysisComputeStage {
        if stage == .main { return .main }
        if stage == .postProcessing { return .postProcessing }
        return .other
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func map(_ stage: ComputeStage) -> MLNativeAnalysisComputeStage {
        switch stage {
        case .main: .main
        case .postProcessing: .postProcessing
        @unknown default: .other
        }
    }

    private static func map(_ device: MLComputeDevice) -> MLNativeAnalysisComputeDevice {
        switch device {
        case .cpu: .cpu
        case .gpu: .gpu
        case .neuralEngine: .neuralEngine
        @unknown default: .other
        }
    }

    private static func uniqueDevices(
        _ devices: [MLNativeAnalysisComputeDevice]
    ) -> [MLNativeAnalysisComputeDevice] {
        var seen: Set<MLNativeAnalysisComputeDevice> = []
        return devices.filter { seen.insert($0).inserted }
    }

    private static func unavailable(
        _ kind: MLNativeAnalysisKind,
        reason: MLNativeAnalysisUnavailableReason
    ) -> MLNativeAnalysisCapability {
        MLNativeAnalysisCapability(
            kind: kind,
            implementationIdentifier: implementationIdentifier(for: kind),
            executionMode: executionMode(for: kind),
            availability: .unavailable(reason),
            selectedRevision: nil,
            supportedRevisions: []
        )
    }

    private static func implementationIdentifier(for kind: MLNativeAnalysisKind) -> String {
        "apple.vision.\(kind.rawValue)"
    }

    private static func executionMode(
        for kind: MLNativeAnalysisKind
    ) -> MLNativeAnalysisExecutionMode {
        AppleVisionCapabilityInventory.entries.first(where: { $0.kind == kind })?.executionMode
            ?? .unsupported
    }
}
