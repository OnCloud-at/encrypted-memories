import MLSearchCore

public enum AppleVisionInputContract: String, Codable, Sendable {
    case boundedStillImage
    case boundedVideoFrames
    case observationAndFrame
    case sourceAndReferenceImage
}

public enum AppleVisionOrientationContract: String, Codable, Sendable {
    case explicitExifOrientation
    case pixelBufferOrientation
}

public enum AppleVisionCropContract: String, Codable, Sendable {
    case fullFrame
    case coreOwnedRegionOfInterest
    case trackedRegion
    case pairedFullFrames
}

public enum AppleVisionPersistenceContract: String, Codable, Sendable {
    case revisionScopedDerived
    case evaluationEvidenceOnly
    case never
}

public struct AppleVisionRequestDataContract: Codable, Equatable, Sendable {
    public let input: AppleVisionInputContract
    public let orientation: AppleVisionOrientationContract
    public let crop: AppleVisionCropContract
    public let outputContract: String
    public let confidenceContract: String
    public let persistence: AppleVisionPersistenceContract
    public let revisionCompatibility: String
}

public struct AppleVisionMeasurementContract: Codable, Equatable, Sendable {
    public let corpusIdentifier: String
    public let passGate: String
}

public struct AppleVisionRequestExclusion: Codable, Equatable, Sendable {
    public let requestName: String
    public let reason: String

    public init(requestName: String, reason: String) {
        self.requestName = requestName
        self.reason = reason
    }
}

/// Stable API inventory. Runtime support and revisions come from `AppleVisionCapabilityProvider`;
/// these entries record product intent and the documented compatibility seam without a device list.
public struct AppleVisionCapabilityInventoryEntry: Codable, Equatable, Sendable {
    public let kind: MLNativeAnalysisKind
    public let swiftRequestName: String
    public let legacyRequestName: String?
    public let minimumIOS: String
    public let minimumMacOS: String
    public let executionMode: MLNativeAnalysisExecutionMode
    public let productConsumers: [String]
    public let fallback: String
    public let dataContract: AppleVisionRequestDataContract
    public let measurement: AppleVisionMeasurementContract

    public init(
        kind: MLNativeAnalysisKind,
        swiftRequestName: String,
        legacyRequestName: String?,
        minimumIOS: String,
        minimumMacOS: String,
        executionMode: MLNativeAnalysisExecutionMode,
        productConsumers: [String],
        fallback: String,
        dataContract: AppleVisionRequestDataContract,
        measurement: AppleVisionMeasurementContract
    ) {
        self.kind = kind
        self.swiftRequestName = swiftRequestName
        self.legacyRequestName = legacyRequestName
        self.minimumIOS = minimumIOS
        self.minimumMacOS = minimumMacOS
        self.executionMode = executionMode
        self.productConsumers = productConsumers
        self.fallback = fallback
        self.dataContract = dataContract
        self.measurement = measurement
    }
}

public enum AppleVisionCapabilityInventory {
    public static let entries: [AppleVisionCapabilityInventoryEntry] = [
        entry(
            .textRecognition, "RecognizeTextRequest", "VNRecognizeTextRequest", "13", "10.15", .indexed, ["OCR search"],
            "Unavailable below the public request minimum."),
        entry(
            .documentRecognition, "RecognizeDocumentsRequest", nil, "26", "26", .indexed,
            ["Structured document search"], "Use document segmentation, text recognition, and barcode detection."),
        entry(
            .barcodeDetection, "DetectBarcodesRequest", "VNDetectBarcodesRequest", "11", "10.13", .indexed,
            ["Barcode search"], "Unavailable below the public request minimum."),
        entry(
            .documentSegmentation, "DetectDocumentSegmentationRequest", "VNDetectDocumentSegmentationRequest", "15",
            "12", .indexed, ["Document routing"], "Run text and barcode requests without structured document regions."),
        entry(
            .imageClassification, "ClassifyImageRequest", "VNClassifyImageRequest", "13", "10.15", .indexed,
            ["Semantic category evidence"], "Use the existing semantic index without native classification evidence."),
        entry(
            .animalRecognition, "RecognizeAnimalsRequest", "VNRecognizeAnimalsRequest", "13", "10.15", .indexed,
            ["Cat and dog routing"], "Do not activate pet-specific stages."),
        entry(
            .humanDetection, "DetectHumanRectanglesRequest", "VNDetectHumanRectanglesRequest", "15", "12", .indexed,
            ["People routing", "Subject counts"], "Use face evidence only."),
        entry(
            .imageFeaturePrint, "GenerateImageFeaturePrintRequest", "VNGenerateImageFeaturePrintRequest", "13", "10.15",
            .indexed, ["Visual similarity candidates"], "Hide visual-similarity search."),
        entry(
            .faceDetection, "DetectFaceRectanglesRequest", "VNDetectFaceRectanglesRequest", "11", "10.13", .indexed,
            ["People detection"], "People recognition is unavailable."),
        entry(
            .faceLandmarks, "DetectFaceLandmarksRequest", "VNDetectFaceLandmarksRequest", "11", "10.13", .indexed,
            ["Face alignment"], "People recognition is unavailable."),
        entry(
            .faceCaptureQuality, "DetectFaceCaptureQualityRequest", "VNDetectFaceCaptureQualityRequest", "13", "10.15",
            .indexed, ["Face filtering", "Representative selection"], "Use geometry-only conservative face filtering."),
        entry(
            .animalBodyPose, "DetectAnimalBodyPoseRequest", "VNDetectAnimalBodyPoseRequest", "17", "14", .onDemand,
            ["Pet crop qualification"], "Use cat and dog recognition regions only."),
        entry(
            .foregroundInstanceMask, "GenerateForegroundInstanceMaskRequest", "VNGenerateForegroundInstanceMaskRequest",
            "17", "14", .onDemand, ["Interactive crop proposals"], "Use detector rectangles without masks."),
        entry(
            .personInstanceMask, "GeneratePersonInstanceMaskRequest", "VNGeneratePersonInstanceMaskRequest", "17", "14",
            .onDemand, ["Interactive person selection"], "Use person rectangles."),
        entry(
            .personSegmentation, "GeneratePersonSegmentationRequest", "VNGeneratePersonSegmentationRequest", "15", "12",
            .onDemand, ["Interactive person masking"], "Use person rectangles."),
        entry(
            .imageAesthetics, "CalculateImageAestheticsScoresRequest", nil, "18", "15", .indexed,
            ["Representative selection"], "Use existing deterministic cover policy."),
        entry(
            .attentionSaliency, "GenerateAttentionBasedSaliencyImageRequest",
            "VNGenerateAttentionBasedSaliencyImageRequest", "13", "10.15", .onDemand,
            ["Interactive attention crop proposals"], "Use fitted image geometry."),
        entry(
            .objectnessSaliency, "GenerateObjectnessBasedSaliencyImageRequest",
            "VNGenerateObjectnessBasedSaliencyImageRequest", "13", "10.15", .indexed,
            ["Subject routing", "Future crop proposals"], "Use fitted image geometry."),
        entry(
            .lensSmudgeDetection, "DetectLensSmudgeRequest", nil, "26", "26", .indexed, ["Capture quality evidence"],
            "Omit lens-smudge evidence."),
        entry(
            .humanBodyPose, "DetectHumanBodyPoseRequest", "VNDetectHumanBodyPoseRequest", "14", "11", .onDemand,
            ["Interactive activity analysis"], "Omit body-pose evidence."),
        entry(
            .humanHandPose, "DetectHumanHandPoseRequest", "VNDetectHumanHandPoseRequest", "14", "11", .onDemand,
            ["Interactive gesture analysis"], "Omit hand-pose evidence."),
        entry(
            .humanBodyPose3D, "DetectHumanBodyPose3DRequest", "VNDetectHumanBodyPose3DRequest", "17", "14", .onDemand,
            ["Interactive spatial pose analysis"], "Use 2D pose evidence."),
        entry(
            .contours, "DetectContoursRequest", "VNDetectContoursRequest", "14", "11", .onDemand,
            ["Interactive shape analysis"], "Omit contour evidence."),
        entry(
            .horizon, "DetectHorizonRequest", "VNDetectHorizonRequest", "11", "10.13", .indexed,
            ["Straightening and quality evidence"], "Omit horizon evidence."),
        entry(
            .rectangles, "DetectRectanglesRequest", "VNDetectRectanglesRequest", "11", "10.13", .onDemand,
            ["Interactive document and shape analysis"], "Omit rectangle evidence."),
        entry(
            .textRectangles, "DetectTextRectanglesRequest", "VNDetectTextRectanglesRequest", "11", "10.13", .indexed,
            ["Text-layout evidence"], "Use recognized text bounds."),
        entry(
            .trajectories, "DetectTrajectoriesRequest", "VNDetectTrajectoriesRequest", "14", "11", .temporalOrPairwise,
            ["Future bounded video consumer"], "Keep disabled without a temporal input model."),
        entry(
            .pairwiseOpticalFlow, "VNGenerateOpticalFlowRequest", "VNGenerateOpticalFlowRequest", "14", "11",
            .temporalOrPairwise, ["Future bounded source/reference comparison"],
            "Keep disabled without two same-sized images and a bounded consumer."),
        entry(
            .opticalFlow, "TrackOpticalFlowRequest", "VNTrackOpticalFlowRequest", "17", "14", .temporalOrPairwise,
            ["Future bounded video consumer"], "Keep disabled without a temporal input model."),
        entry(
            .objectTracking, "TrackObjectRequest", "VNTrackObjectRequest", "11", "10.13", .temporalOrPairwise,
            ["Future bounded video consumer"], "Keep disabled without an observation and frame sequence."),
        entry(
            .rectangleTracking, "TrackRectangleRequest", "VNTrackRectangleRequest", "11", "10.13", .temporalOrPairwise,
            ["Future bounded video consumer"], "Keep disabled without an observation and frame sequence."),
        entry(
            .translationalImageRegistration, "TrackTranslationalImageRegistrationRequest",
            "VNTranslationalImageRegistrationRequest", "11", "10.13", .temporalOrPairwise,
            ["Future reference-image consumer"], "Keep disabled without paired images."),
        entry(
            .homographicImageRegistration, "TrackHomographicImageRegistrationRequest",
            "VNHomographicImageRegistrationRequest", "11", "10.13", .temporalOrPairwise,
            ["Future reference-image consumer"], "Keep disabled without paired images."),
        entry(
            .iterativeSegmentation, "GenerateIterativeSegmentationRequest", nil, "27", "27", .onDemand,
            ["Interactive subject selection"], "Use foreground instance masks."),
    ]

    /// Vision requests intentionally handled outside this inventory. The SDK-surface gate requires
    /// every public `RequestDescriptor` case to be inventoried or explained here.
    public static let exclusions: [AppleVisionRequestExclusion] = [
        AppleVisionRequestExclusion(
            requestName: "CoreMLRequest",
            reason:
                "Custom model transport, not a built-in Vision analysis. Encrypted Memories keeps exact model preprocessing and tensor contracts in the existing Core ML runtime."
        )
    ]

    private static func entry(
        _ kind: MLNativeAnalysisKind,
        _ swiftRequestName: String,
        _ legacyRequestName: String?,
        _ minimumIOS: String,
        _ minimumMacOS: String,
        _ executionMode: MLNativeAnalysisExecutionMode,
        _ consumers: [String],
        _ fallback: String
    ) -> AppleVisionCapabilityInventoryEntry {
        AppleVisionCapabilityInventoryEntry(
            kind: kind,
            swiftRequestName: swiftRequestName,
            legacyRequestName: legacyRequestName,
            minimumIOS: minimumIOS,
            minimumMacOS: minimumMacOS,
            executionMode: executionMode,
            productConsumers: consumers,
            fallback: fallback,
            dataContract: dataContract(for: kind, executionMode: executionMode),
            measurement: measurementContract(for: kind)
        )
    }

    private static func dataContract(
        for kind: MLNativeAnalysisKind,
        executionMode: MLNativeAnalysisExecutionMode
    ) -> AppleVisionRequestDataContract {
        let input: AppleVisionInputContract
        let orientation: AppleVisionOrientationContract
        let crop: AppleVisionCropContract
        switch kind {
        case .trajectories, .opticalFlow:
            input = .boundedVideoFrames
            orientation = .pixelBufferOrientation
            crop = .fullFrame
        case .pairwiseOpticalFlow:
            input = .sourceAndReferenceImage
            orientation = .explicitExifOrientation
            crop = .pairedFullFrames
        case .objectTracking, .rectangleTracking:
            input = .observationAndFrame
            orientation = .pixelBufferOrientation
            crop = .trackedRegion
        case .translationalImageRegistration, .homographicImageRegistration:
            input = .sourceAndReferenceImage
            orientation = .explicitExifOrientation
            crop = .pairedFullFrames
        case .faceLandmarks, .faceCaptureQuality, .iterativeSegmentation:
            input = .boundedStillImage
            orientation = .explicitExifOrientation
            crop = .coreOwnedRegionOfInterest
        default:
            input = .boundedStillImage
            orientation = .explicitExifOrientation
            crop = .fullFrame
        }

        let persistence: AppleVisionPersistenceContract =
            switch executionMode {
            case .indexed: .revisionScopedDerived
            case .onDemand, .temporalOrPairwise, .unsupported: .never
            }
        let output = outputContract(for: kind)
        return AppleVisionRequestDataContract(
            input: input,
            orientation: orientation,
            crop: crop,
            outputContract: output,
            confidenceContract: confidenceContract(for: kind),
            persistence: persistence,
            revisionCompatibility: persistence == .never
                ? "Not persisted or compared across runs."
                : "Compatible only within the same request, revision, preprocessing revision, and schema epoch."
        )
    }

    private static func outputContract(for kind: MLNativeAnalysisKind) -> String {
        switch kind {
        case .textRecognition: "Recognized text candidates, quadrilaterals, and confidence."
        case .documentRecognition: "Structured document hierarchy with text, tables, lists, and barcodes."
        case .barcodeDetection: "Barcode payload, symbology, geometry, and confidence."
        case .documentSegmentation: "Document region observation."
        case .imageClassification: "Revision-scoped classification identifiers and confidence."
        case .animalRecognition: "Cat or dog label, region, and confidence."
        case .humanDetection: "Human rectangles and confidence."
        case .imageFeaturePrint: "Element type, element count, and bounded raw feature-print bytes."
        case .faceDetection: "Face rectangles and confidence."
        case .faceLandmarks: "Face landmark regions tied to an input face observation."
        case .faceCaptureQuality: "Face capture-quality score tied to an input face observation."
        case .animalBodyPose: "Recognized animal body points and confidence."
        case .foregroundInstanceMask, .personInstanceMask, .personSegmentation:
            "Persisted compact instance count, bounded regions, and sampled coverage; full masks remain on demand."
        case .imageAesthetics: "Overall utility and aesthetic scores."
        case .attentionSaliency, .objectnessSaliency:
            "Persisted bounded salient regions and coverage only; heat maps are not stored."
        case .lensSmudgeDetection: "Lens-smudge confidence."
        case .humanBodyPose, .humanHandPose, .humanBodyPose3D:
            "Recognized body or hand points and confidence."
        case .contours: "Compact contour count and bounding-region summary."
        case .horizon: "Horizon angle observation."
        case .rectangles: "Rectangle observations and confidence."
        case .textRectangles: "Visible text regions and confidence."
        case .trajectories: "Detected trajectory observations over bounded frames."
        case .pairwiseOpticalFlow: "Pixel-buffer optical-flow field between two explicit images."
        case .opticalFlow: "Pixel-buffer optical-flow field."
        case .objectTracking, .rectangleTracking: "Updated tracked observation and confidence."
        case .translationalImageRegistration, .homographicImageRegistration:
            "Image alignment transform."
        case .iterativeSegmentation: "User-seeded subject mask generated on demand."
        }
    }

    private static func confidenceContract(for kind: MLNativeAnalysisKind) -> String {
        switch kind {
        case .imageFeaturePrint, .foregroundInstanceMask, .personInstanceMask, .personSegmentation,
            .attentionSaliency, .objectnessSaliency, .pairwiseOpticalFlow, .opticalFlow,
            .translationalImageRegistration, .homographicImageRegistration, .iterativeSegmentation:
            "No cross-request confidence scale; use only request-specific output semantics."
        default:
            "Treat confidence as request- and revision-local; calibrate before applying a product threshold."
        }
    }

    private static func measurementContract(
        for kind: MLNativeAnalysisKind
    ) -> AppleVisionMeasurementContract {
        let corpus: String
        let usefulnessGate: String
        switch kind {
        case .textRecognition, .documentRecognition, .barcodeDetection, .documentSegmentation:
            corpus = "vision-documents-de-en-v1"
            usefulnessGate = "Meets the task-specific German/English text, document, or barcode accuracy gate."
        case .imageClassification:
            corpus = "vision-native-labels-v1"
            usefulnessGate = "Improves calibrated category precision or recall over semantic search alone."
        case .animalRecognition, .animalBodyPose:
            corpus = "vision-pet-routing-v1"
            usefulnessGate = "Meets the pet routing recall gate without unacceptable false positives."
        case .imageFeaturePrint:
            corpus = "vision-similarity-v1"
            usefulnessGate = "Improves similar-photo candidates without affecting backup deduplication."
        case .humanDetection, .faceDetection, .faceLandmarks, .faceCaptureQuality,
            .humanBodyPose, .humanHandPose, .humanBodyPose3D:
            corpus = "vision-people-detection-v1"
            usefulnessGate = "Meets face detection, alignment, and filtering gates on the frozen people corpus."
        case .foregroundInstanceMask, .personInstanceMask, .personSegmentation, .imageAesthetics,
            .attentionSaliency, .objectnessSaliency, .lensSmudgeDetection:
            corpus = "vision-quality-subjects-v1"
            usefulnessGate = "Produces measurable product value within the injected latency and memory budgets."
        default:
            corpus = "vision-capability-smoke-v1"
            usefulnessGate =
                "Remains disabled until a product task defines accuracy, latency, memory, and energy gates."
        }
        return AppleVisionMeasurementContract(
            corpusIdentifier: corpus,
            passGate: "Passes cold/warm latency, peak memory, energy, and output usefulness checks. \(usefulnessGate)"
        )
    }
}
