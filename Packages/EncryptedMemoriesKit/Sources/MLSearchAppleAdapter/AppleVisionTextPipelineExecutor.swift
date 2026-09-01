import CoreGraphics
import Foundation
import ImageIO
import MLSearchCore
import PhotosCore
@preconcurrency import Vision

public final class AppleVisionPipelineExecutor: MLDerivedPipelineExecutor, Sendable {
    typealias Analyze =
        @Sendable (
            CoreMLSourceImage,
            [MLNativeAnalysisKind: MLNativeResultContext]
        ) async throws -> [MLNativeAnalysisKind: MLDerivedPipelineOutput]

    enum ArtifactAnalysisResult: Equatable, Sendable {
        case completed(MLDerivedPipelineOutput)
        case completedEmpty
        case unsupported
        case retryableFailure(MLPipelineFailureReason)
        case permanentFailure(MLPipelineFailureReason)
    }

    typealias AnalyzeResults =
        @Sendable (
            CoreMLSourceImage,
            [MLNativeAnalysisKind: MLNativeResultContext]
        ) async -> [MLNativeAnalysisKind: ArtifactAnalysisResult]

    private let imageSource: any CoreMLImageSource
    private let analyze: AnalyzeResults

    struct StructuredDocumentSnapshot: Sendable {
        let languages: [String]
        let text: [MLTextObservation]
        let barcodes: [MLBarcodeObservation]
        let regions: [MLDocumentRegion]
    }

    public init(imageSource: any CoreMLImageSource) {
        self.imageSource = imageSource
        self.analyze = Self.analyzeWithVision
    }

    init(imageSource: any CoreMLImageSource, analyze: @escaping Analyze) {
        self.imageSource = imageSource
        self.analyze = { source, contexts in
            do {
                return try await analyze(source, contexts).mapValues(ArtifactAnalysisResult.completed)
            } catch is CancellationError {
                return [:]
            } catch {
                return Dictionary(
                    uniqueKeysWithValues: contexts.keys.map {
                        ($0, .retryableFailure(.analysisFailed))
                    })
            }
        }
    }

    init(imageSource: any CoreMLImageSource, resultAnalyzer: @escaping AnalyzeResults) {
        self.imageSource = imageSource
        self.analyze = resultAnalyzer
    }

    public func execute(_ plan: MLAssetAnalysisPlan) async -> [MLPipelineStageResult] {
        let contexts: [MLNativeAnalysisKind: MLNativeResultContext]
        do {
            contexts = try Dictionary(
                uniqueKeysWithValues: plan.workItems.compactMap { item in
                    guard case .native(let provider, let kind, let revision) = item.artifact.producer else {
                        return nil
                    }
                    return (
                        kind,
                        try MLNativeResultContext(
                            providerIdentifier: provider,
                            analysisKind: kind,
                            requestRevision: revision,
                            preprocessingRevision: item.artifact.preprocessingRevision,
                            schemaEpoch: item.artifact.schemaEpoch
                        )
                    )
                })
        } catch {
            return plan.workItems.map {
                .init(workItem: $0, outcome: .permanentInputFailure(reason: .invalidArtifactContract))
            }
        }
        guard contexts.count == plan.workItems.count else {
            return plan.workItems.map {
                .init(workItem: $0, outcome: .permanentInputFailure(reason: .invalidArtifactContract))
            }
        }

        switch await imageSource.image(for: plan.asset.uid) {
        case .permanentFailure(let reason):
            let outcome: MLPipelineStageOutcome =
                reason == "thumbnail unavailable from backend"
                ? .skipped(.sourceUnavailable)
                : .permanentInputFailure(reason: .sourceCorrupt)
            return plan.workItems.map { .init(workItem: $0, outcome: outcome) }
        case .transientFailure:
            return plan.workItems.map {
                .init(workItem: $0, outcome: .deferred(reason: .sourceNotResident, retryAfter: nil))
            }
        case .image(let source):
            let outputs = await analyze(source, contexts)
            if Task.isCancelled {
                return plan.workItems.map { .init(workItem: $0, outcome: .cancelled) }
            }
            return plan.workItems.map { item in
                guard case .native(_, let kind, _) = item.artifact.producer else {
                    return .init(workItem: item, outcome: .permanentInputFailure(reason: .invalidArtifactContract))
                }
                let outcome: MLPipelineStageOutcome =
                    switch outputs[kind] ?? .completedEmpty {
                    case .completed(let output): .completed(output)
                    case .completedEmpty: .completedEmpty
                    case .unsupported: .skipped(.unsupportedCapability)
                    case .retryableFailure(let reason): .retryableFailure(reason: reason, retryAfter: nil)
                    case .permanentFailure(let reason): .permanentInputFailure(reason: reason)
                    }
                return .init(workItem: item, outcome: outcome)
            }
        }
    }

    private static func analyzeWithVision(
        source: CoreMLSourceImage,
        contexts: [MLNativeAnalysisKind: MLNativeResultContext]
    ) async -> [MLNativeAnalysisKind: ArtifactAnalysisResult] {
        guard #available(macOS 15.0, iOS 18.0, *) else {
            return Dictionary(uniqueKeysWithValues: contexts.keys.map { ($0, .unsupported) })
        }
        var results = await analyzeRoutingRequests(source: source, contexts: contexts)
        let textKinds: Set<MLNativeAnalysisKind> = [
            .textRecognition, .documentRecognition, .barcodeDetection,
        ]
        let textContexts = contexts.filter { textKinds.contains($0.key) }
        if !textContexts.isEmpty {
            results.merge(
                await analyzeTextRequests(
                    source: source,
                    contexts: textContexts,
                    routingResults: results
                ),
                uniquingKeysWith: { _, newer in newer }
            )
        }
        let routedKinds: Set<MLNativeAnalysisKind> = [
            .documentSegmentation, .textRectangles,
        ]
        let otherContexts = contexts.filter {
            !textKinds.contains($0.key) && !routedKinds.contains($0.key)
        }
        results.merge(
            await analyzeAdditionalRequests(source: source, contexts: otherContexts),
            uniquingKeysWith: { _, newer in newer }
        )
        return results
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func analyzeTextRequests(
        source: CoreMLSourceImage,
        contexts: [MLNativeAnalysisKind: MLNativeResultContext],
        routingResults: [MLNativeAnalysisKind: ArtifactAnalysisResult]
    ) async -> [MLNativeAnalysisKind: ArtifactAnalysisResult] {
        let handler = ImageRequestHandler(source.cgImage, orientation: source.orientation)
        var results: [MLNativeAnalysisKind: ArtifactAnalysisResult] = [:]
        let barcodeDetectionRevision =
            await AppleVisionRuntimeSupport
            .barcodeDetectionRevisionIdentifier()
        let barcodeContextMatchesRuntime =
            contexts[.barcodeDetection].map { context in
                guard let barcodeDetectionRevision else { return false }
                return context.requestRevision == barcodeDetectionRevision
            } ?? false
        if contexts[.barcodeDetection] != nil, !barcodeContextMatchesRuntime {
            results[.barcodeDetection] = .unsupported
        }

        if let documentContext = contexts[.documentRecognition] {
            switch routingDecision(for: routingResults[.documentSegmentation]) {
            case .skip:
                results[.documentRecognition] = .completedEmpty
            case .retry:
                results[.documentRecognition] = .retryableFailure(.analysisFailed)
            case .run:
                if #available(macOS 26.0, iOS 26.0, *) {
                    do {
                        if let snapshot = try await structuredDocumentSnapshot(
                            handler: handler,
                            requestRevision: documentContext.requestRevision,
                            includeBarcodes: barcodeContextMatchesRuntime
                        ) {
                            let outputs = try encodedDocumentOutputs(snapshot, contexts: contexts)
                            for (kind, output) in outputs { results[kind] = .completed(output) }
                            if results[.documentRecognition] == nil {
                                results[.documentRecognition] = .completedEmpty
                            }
                        } else {
                            results[.documentRecognition] = .completedEmpty
                        }
                    } catch is CancellationError {
                        return [:]
                    } catch is MLAnalysisContractError {
                        results[.documentRecognition] = .permanentFailure(.invalidArtifactContract)
                    } catch {
                        results[.documentRecognition] = .retryableFailure(.analysisFailed)
                    }
                } else {
                    results[.documentRecognition] = .unsupported
                }
            }
        }

        if contexts[.barcodeDetection] != nil, results[.barcodeDetection] == nil {
            do {
                let outputs = try await analyzeModernTextAndBarcodes(
                    handler: handler,
                    contexts: contexts,
                    needsText: false,
                    needsBarcode: true
                )
                results[.barcodeDetection] =
                    outputs[.barcodeDetection]
                    .map(ArtifactAnalysisResult.completed) ?? .completedEmpty
            } catch is CancellationError {
                return [:]
            } catch is MLAnalysisContractError {
                results[.barcodeDetection] = .permanentFailure(.invalidArtifactContract)
            } catch {
                results[.barcodeDetection] = .retryableFailure(.analysisFailed)
            }
        }

        if contexts[.textRecognition] != nil, results[.textRecognition] == nil {
            switch routingDecision(for: routingResults[.textRectangles]) {
            case .skip:
                results[.textRecognition] = .completedEmpty
            case .retry:
                results[.textRecognition] = .retryableFailure(.analysisFailed)
            case .run:
                do {
                    let outputs = try await analyzeModernTextAndBarcodes(
                        handler: handler,
                        contexts: contexts,
                        needsText: true,
                        needsBarcode: false
                    )
                    results[.textRecognition] =
                        outputs[.textRecognition]
                        .map(ArtifactAnalysisResult.completed) ?? .completedEmpty
                } catch is CancellationError {
                    return [:]
                } catch is MLAnalysisContractError {
                    results[.textRecognition] = .permanentFailure(.invalidArtifactContract)
                } catch {
                    results[.textRecognition] = .retryableFailure(.analysisFailed)
                }
            }
        }
        return results
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func analyzeModernTextAndBarcodes(
        handler: ImageRequestHandler,
        contexts: [MLNativeAnalysisKind: MLNativeResultContext],
        needsText: Bool,
        needsBarcode: Bool
    ) async throws -> [MLNativeAnalysisKind: MLDerivedPipelineOutput] {
        guard needsText || needsBarcode else { return [:] }
        let textRevision = contexts[.textRecognition].flatMap {
            selectedRevision($0.requestRevision, from: RecognizeTextRequest.supportedRevisions)
        }
        let barcodeRevision = contexts[.barcodeDetection].flatMap {
            selectedRevision($0.requestRevision, from: DetectBarcodesRequest.supportedRevisions)
        }
        guard !needsText || textRevision != nil, !needsBarcode || barcodeRevision != nil else {
            throw AppleVisionExecutorError.unsupportedRevision
        }
        var textRequest = RecognizeTextRequest(textRevision)
        textRequest.recognitionLevel = .accurate
        textRequest.automaticallyDetectsLanguage = true
        textRequest.usesLanguageCorrection = true
        textRequest.recognitionLanguages = preferredLanguages(from: textRequest.supportedRecognitionLanguages)
        var barcodeRequest = DetectBarcodesRequest(barcodeRevision)
        barcodeRequest.symbologies = barcodeRequest.supportedSymbologies

        let textObservations: [RecognizedTextObservation]
        let barcodeObservations: [BarcodeObservation]
        switch (needsText, needsBarcode) {
        case (true, true):
            (textObservations, barcodeObservations) = try await handler.perform(textRequest, barcodeRequest)
        case (true, false):
            textObservations = try await handler.perform(textRequest)
            barcodeObservations = []
        case (false, true):
            textObservations = []
            barcodeObservations = try await handler.perform(barcodeRequest)
        case (false, false):
            return [:]
        }

        var outputs: [MLNativeAnalysisKind: MLDerivedPipelineOutput] = [:]
        if let context = contexts[.textRecognition] {
            let observations = textObservations.compactMap { observation -> MLTextObservation? in
                guard let candidate = observation.topCandidates(1).first,
                    !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let bounds = normalizedRect(points: [
                        observation.topLeft, observation.topRight,
                        observation.bottomRight, observation.bottomLeft,
                    ])
                else { return nil }
                let languages: [String]
                if #available(macOS 26.0, iOS 26.0, *) {
                    languages = observation.recognitionLanguages.map(\.minimalIdentifier)
                } else {
                    languages = []
                }
                return MLTextObservation(
                    text: candidate.string,
                    languages: languages,
                    confidence: candidate.confidence,
                    bounds: bounds
                )
            }
            if !observations.isEmpty {
                let artifact = try MLRecognizedTextArtifact(context: context, observations: observations)
                outputs[.textRecognition] = try encodedOutput(
                    artifact,
                    searchableText: observations.map(\.text)
                )
            }
        }
        if let context = contexts[.barcodeDetection] {
            let observations = barcodeObservations.compactMap { observation -> MLBarcodeObservation? in
                guard let payload = observation.payloadString, !payload.isEmpty,
                    let bounds = normalizedRect(points: [
                        observation.topLeft, observation.topRight,
                        observation.bottomRight, observation.bottomLeft,
                    ])
                else { return nil }
                return MLBarcodeObservation(
                    payload: payload,
                    symbology: String(describing: observation.symbology),
                    confidence: observation.confidence,
                    bounds: bounds
                )
            }
            if !observations.isEmpty {
                let artifact = try MLBarcodeArtifact(context: context, observations: observations)
                outputs[.barcodeDetection] = try encodedOutput(
                    artifact,
                    searchableText: observations.map(\.payload)
                )
            }
        }
        return outputs
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func structuredDocumentSnapshot(
        handler: ImageRequestHandler,
        requestRevision: String,
        includeBarcodes: Bool
    ) async throws -> StructuredDocumentSnapshot? {
        guard
            let revision = selectedRevision(
                requestRevision,
                from: RecognizeDocumentsRequest.supportedRevisions
            )
        else {
            throw AppleVisionExecutorError.unsupportedRevision
        }
        var request = RecognizeDocumentsRequest(revision)
        var textOptions = request.textRecognitionOptions
        textOptions.automaticallyDetectLanguage = true
        textOptions.useLanguageCorrection = true
        textOptions.recognitionLanguages = preferredLanguages(from: request.supportedRecognitionLanguages)
        textOptions.maximumCandidateCount = 1
        request.textRecognitionOptions = textOptions
        var barcodeOptions = request.barcodeDetectionOptions
        barcodeOptions.enabled = includeBarcodes
        barcodeOptions.symbologies = includeBarcodes ? request.supportedBarcodeSymbologies : []
        request.barcodeDetectionOptions = barcodeOptions

        guard let document = try await handler.perform(request).first?.document else { return nil }
        let languages = textOptions.recognitionLanguages.map(\.minimalIdentifier)
        let text = document.text.lines.compactMap(textObservation)
        let barcodes = includeBarcodes ? documentBarcodes(in: document) : []
        let regions = documentRegions(in: document)
        guard !text.isEmpty || !barcodes.isEmpty || !regions.isEmpty else { return nil }
        return StructuredDocumentSnapshot(
            languages: languages,
            text: text,
            barcodes: barcodes,
            regions: regions
        )
    }

    static func encodedDocumentOutputs(
        _ snapshot: StructuredDocumentSnapshot,
        contexts: [MLNativeAnalysisKind: MLNativeResultContext]
    ) throws -> [MLNativeAnalysisKind: MLDerivedPipelineOutput] {
        var outputs: [MLNativeAnalysisKind: MLDerivedPipelineOutput] = [:]
        if let context = contexts[.documentRecognition], !snapshot.regions.isEmpty {
            outputs[.documentRecognition] = try encodedOutput(
                MLStructuredDocumentArtifact(
                    context: context,
                    languages: snapshot.languages,
                    regions: snapshot.regions
                ),
                searchableText: snapshot.regions.map(\.text)
            )
        }
        if let context = contexts[.textRecognition], !snapshot.text.isEmpty {
            outputs[.textRecognition] = try encodedOutput(
                MLRecognizedTextArtifact(context: context, observations: snapshot.text),
                searchableText: snapshot.text.map(\.text)
            )
        }
        if let context = contexts[.barcodeDetection], !snapshot.barcodes.isEmpty {
            outputs[.barcodeDetection] = try encodedOutput(
                MLBarcodeArtifact(context: context, observations: snapshot.barcodes),
                searchableText: snapshot.barcodes.map(\.payload)
            )
        }
        return outputs
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func documentRegions(
        in document: DocumentObservation.Container
    ) -> [MLDocumentRegion] {
        var regions: [MLDocumentRegion] = []
        if let title = document.title, let region = documentRegion(kind: .heading, text: title) {
            regions.append(region)
        }
        regions.append(
            contentsOf: document.paragraphs.compactMap {
                documentRegion(kind: .paragraph, text: $0)
            })
        for (listIndex, list) in document.lists.enumerated() {
            for (itemIndex, item) in list.items.enumerated() {
                let value = item.itemString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty,
                    let bounds = normalizedRect(item.content.boundingRegion.boundingBox)
                else { continue }
                regions.append(
                    MLDocumentRegion(
                        kind: .listItem,
                        text: value,
                        groupIndex: listIndex,
                        itemIndex: itemIndex,
                        marker: item.markerString.isEmpty ? nil : item.markerString,
                        confidence: averageConfidence(item.content.text.lines),
                        bounds: bounds
                    ))
            }
        }
        for (tableIndex, table) in document.tables.enumerated() {
            var seen: Set<String> = []
            for cell in table.rows.flatMap({ $0 }) {
                let value = cell.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                let key =
                    "\(cell.rowRange.lowerBound):\(cell.rowRange.upperBound):\(cell.columnRange.lowerBound):\(cell.columnRange.upperBound):\(value)"
                guard !value.isEmpty, seen.insert(key).inserted,
                    let bounds = normalizedRect(cell.content.boundingRegion.boundingBox)
                else { continue }
                regions.append(
                    MLDocumentRegion(
                        kind: .tableCell,
                        text: value,
                        groupIndex: tableIndex,
                        row: cell.rowRange.lowerBound,
                        rowSpan: cell.rowRange.count,
                        column: cell.columnRange.lowerBound,
                        columnSpan: cell.columnRange.count,
                        confidence: averageConfidence(cell.content.text.lines),
                        bounds: bounds
                    ))
            }
        }
        if regions.isEmpty, let region = documentRegion(kind: .other, text: document.text) {
            regions.append(region)
        }
        return regions
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func documentRegion(
        kind: MLDocumentRegionKind,
        text: DocumentObservation.Container.Text
    ) -> MLDocumentRegion? {
        let value = text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let bounds = normalizedRect(text.boundingRegion.boundingBox) else { return nil }
        return MLDocumentRegion(
            kind: kind,
            text: value,
            confidence: averageConfidence(text.lines),
            bounds: bounds
        )
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func textObservation(_ observation: RecognizedTextObservation) -> MLTextObservation? {
        guard let candidate = observation.topCandidates(1).first,
            !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let bounds = normalizedRect(points: [
                observation.topLeft, observation.topRight,
                observation.bottomRight, observation.bottomLeft,
            ])
        else { return nil }
        return MLTextObservation(
            text: candidate.string,
            languages: observation.recognitionLanguages.map(\.minimalIdentifier),
            confidence: candidate.confidence,
            bounds: bounds
        )
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func averageConfidence(_ lines: [RecognizedTextObservation]) -> Float {
        let values = lines.compactMap { $0.topCandidates(1).first?.confidence }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func documentBarcodes(
        in document: DocumentObservation.Container
    ) -> [MLBarcodeObservation] {
        var result: [MLBarcodeObservation] = []
        var seen: Set<String> = []
        result.reserveCapacity(document.barcodes.count)

        // The root container reports the document's machine-readable codes. Nested content is not
        // a safely traversable tree and may lead back into containers already visited by Vision.
        for observation in document.barcodes {
            guard let payload = observation.payloadString, !payload.isEmpty,
                let bounds = normalizedRect(points: [
                    observation.topLeft, observation.topRight,
                    observation.bottomRight, observation.bottomLeft,
                ])
            else { continue }
            let key = "\(observation.symbology):\(payload):\(bounds.x):\(bounds.y):\(bounds.width):\(bounds.height)"
            guard seen.insert(key).inserted else { continue }
            result.append(
                MLBarcodeObservation(
                    payload: payload,
                    symbology: String(describing: observation.symbology),
                    confidence: observation.confidence,
                    bounds: bounds
                ))
        }
        return result
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func preferredLanguages(
        from supported: [Locale.Language]
    ) -> [Locale.Language] {
        let preferredPrefixes = ["de", "en"]
        return preferredPrefixes.compactMap { prefix in
            supported.first { $0.minimalIdentifier.hasPrefix(prefix) }
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func normalizedRect(points: [NormalizedPoint]) -> MLNormalizedRect? {
        let xs = points.map { Double($0.x) }
        let ys = points.map { Double($0.y) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return nil
        }
        return try? MLNormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func normalizedRect(_ rect: CGRect) -> MLNormalizedRect? {
        try? MLNormalizedRect(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func normalizedRect(_ rect: Vision.NormalizedRect) -> MLNormalizedRect? {
        normalizedRect(rect.cgRect)
    }

    private static func encodedOutput<T: Encodable>(
        _ artifact: T,
        searchableText: [String]
    ) throws -> MLDerivedPipelineOutput {
        MLDerivedPipelineOutput(
            payload: try JSONEncoder().encode(artifact),
            normalizedSearchTokens: MLTextIndexNormalizer.tokens(in: searchableText)
        )
    }
}

@available(macOS 15.0, iOS 18.0, *)
private extension AppleVisionPipelineExecutor {
    static func selectedRevision<Revision>(
        _ identifier: String,
        from revisions: [Revision]
    ) -> Revision? {
        revisions.first { String(describing: $0) == identifier }
    }

    static func analyzeRoutingRequests(
        source: CoreMLSourceImage,
        contexts: [MLNativeAnalysisKind: MLNativeResultContext]
    ) async -> [MLNativeAnalysisKind: ArtifactAnalysisResult] {
        let routingKinds: [MLNativeAnalysisKind] = [
            .documentSegmentation,
            .textRectangles,
        ]
        let handler = ImageRequestHandler(source.cgImage, orientation: source.orientation)
        var results: [MLNativeAnalysisKind: ArtifactAnalysisResult] = [:]
        for kind in routingKinds {
            guard let context = contexts[kind] else { continue }
            results[kind] = await analyze(kind: kind, context: context, handler: handler)
        }
        return results
    }

    static func analyzeAdditionalRequests(
        source: CoreMLSourceImage,
        contexts: [MLNativeAnalysisKind: MLNativeResultContext]
    ) async -> [MLNativeAnalysisKind: ArtifactAnalysisResult] {
        guard !contexts.isEmpty else { return [:] }
        let handler = ImageRequestHandler(source.cgImage, orientation: source.orientation)
        var results: [MLNativeAnalysisKind: ArtifactAnalysisResult] = [:]
        let faceKinds: Set<MLNativeAnalysisKind> = [
            .faceDetection, .faceLandmarks, .faceCaptureQuality,
        ]

        for kind in MLNativeAnalysisKind.allCases {
            guard !faceKinds.contains(kind), let context = contexts[kind] else { continue }
            results[kind] = await analyze(kind: kind, context: context, handler: handler)
        }
        let faceContexts = contexts.filter { faceKinds.contains($0.key) }
        if !faceContexts.isEmpty {
            results.merge(
                await analyzeFaceRequests(handler: handler, contexts: faceContexts),
                uniquingKeysWith: { _, newer in newer }
            )
        }
        return results
    }

    static func analyzeFaceRequests(
        handler: ImageRequestHandler,
        contexts: [MLNativeAnalysisKind: MLNativeResultContext]
    ) async -> [MLNativeAnalysisKind: ArtifactAnalysisResult] {
        guard let detectionContext = contexts[.faceDetection] else {
            var results: [MLNativeAnalysisKind: ArtifactAnalysisResult] = [:]
            for kind in [MLNativeAnalysisKind.faceLandmarks, .faceCaptureQuality] {
                guard let context = contexts[kind] else { continue }
                results[kind] = await analyze(kind: kind, context: context, handler: handler)
            }
            return results
        }
        guard
            let revision = selectedRevision(
                detectionContext.requestRevision,
                from: DetectFaceRectanglesRequest.supportedRevisions
            )
        else {
            return Dictionary(uniqueKeysWithValues: contexts.keys.map { ($0, .unsupported) })
        }

        do {
            let faces = try await handler.perform(DetectFaceRectanglesRequest(revision))
            var results: [MLNativeAnalysisKind: ArtifactAnalysisResult] = [:]
            results[.faceDetection] =
                try faceRegionsOutput(faces, context: detectionContext)
                .map(ArtifactAnalysisResult.completed) ?? .completedEmpty
            guard !faces.isEmpty else {
                if contexts[.faceLandmarks] != nil { results[.faceLandmarks] = .completedEmpty }
                if contexts[.faceCaptureQuality] != nil { results[.faceCaptureQuality] = .completedEmpty }
                return results
            }

            if let context = contexts[.faceLandmarks] {
                results[.faceLandmarks] = await performFaceLandmarks(
                    faces: faces,
                    context: context,
                    handler: handler
                )
            }
            if let context = contexts[.faceCaptureQuality] {
                results[.faceCaptureQuality] = await performFaceQuality(
                    faces: faces,
                    context: context,
                    handler: handler
                )
            }
            return results
        } catch is CancellationError {
            return Dictionary(
                uniqueKeysWithValues: contexts.keys.map {
                    ($0, .retryableFailure(.analysisFailed))
                })
        } catch is MLAnalysisContractError {
            return Dictionary(
                uniqueKeysWithValues: contexts.keys.map {
                    ($0, .permanentFailure(.invalidArtifactContract))
                })
        } catch {
            return Dictionary(
                uniqueKeysWithValues: contexts.keys.map {
                    ($0, .retryableFailure(.analysisFailed))
                })
        }
    }

    static func performFaceLandmarks(
        faces: [FaceObservation],
        context: MLNativeResultContext,
        handler: ImageRequestHandler
    ) async -> ArtifactAnalysisResult {
        guard
            let revision = selectedRevision(
                context.requestRevision,
                from: DetectFaceLandmarksRequest.supportedRevisions
            )
        else { return .unsupported }
        do {
            var request = DetectFaceLandmarksRequest(revision)
            request.inputFaceObservations = faces
            let observations = try await handler.perform(request)
            return try faceLandmarksOutput(observations, context: context)
                .map(ArtifactAnalysisResult.completed) ?? .completedEmpty
        } catch is CancellationError {
            return .retryableFailure(.analysisFailed)
        } catch is MLAnalysisContractError {
            return .permanentFailure(.invalidArtifactContract)
        } catch {
            return .retryableFailure(.analysisFailed)
        }
    }

    static func performFaceQuality(
        faces: [FaceObservation],
        context: MLNativeResultContext,
        handler: ImageRequestHandler
    ) async -> ArtifactAnalysisResult {
        guard
            let revision = selectedRevision(
                context.requestRevision,
                from: DetectFaceCaptureQualityRequest.supportedRevisions
            )
        else { return .unsupported }
        do {
            var request = DetectFaceCaptureQualityRequest(revision)
            request.inputFaceObservations = faces
            let observations = try await handler.perform(request)
            return try faceQualityOutput(observations, context: context)
                .map(ArtifactAnalysisResult.completed) ?? .completedEmpty
        } catch is CancellationError {
            return .retryableFailure(.analysisFailed)
        } catch is MLAnalysisContractError {
            return .permanentFailure(.invalidArtifactContract)
        } catch {
            return .retryableFailure(.analysisFailed)
        }
    }

    static func analyze(
        kind: MLNativeAnalysisKind,
        context: MLNativeResultContext,
        handler: ImageRequestHandler
    ) async -> ArtifactAnalysisResult {
        switch kind {
        case .documentSegmentation:
            return await perform(
                context: context,
                revisions: DetectDocumentSegmentationRequest.supportedRevisions,
                handler: handler,
                request: DetectDocumentSegmentationRequest.init,
                transform: documentSegmentationOutput
            )
        case .imageClassification:
            return await perform(
                context: context,
                revisions: ClassifyImageRequest.supportedRevisions,
                handler: handler,
                request: ClassifyImageRequest.init,
                transform: classificationOutput
            )
        case .animalRecognition:
            return await perform(
                context: context,
                revisions: RecognizeAnimalsRequest.supportedRevisions,
                handler: handler,
                request: RecognizeAnimalsRequest.init,
                transform: animalOutput
            )
        case .humanDetection:
            return await perform(
                context: context,
                revisions: DetectHumanRectanglesRequest.supportedRevisions,
                handler: handler,
                request: DetectHumanRectanglesRequest.init,
                transform: humanOutput
            )
        case .imageFeaturePrint:
            return await perform(
                context: context,
                revisions: GenerateImageFeaturePrintRequest.supportedRevisions,
                handler: handler,
                request: GenerateImageFeaturePrintRequest.init,
                transform: featurePrintOutput
            )
        case .faceDetection:
            return await perform(
                context: context,
                revisions: DetectFaceRectanglesRequest.supportedRevisions,
                handler: handler,
                request: DetectFaceRectanglesRequest.init,
                transform: faceRegionsOutput
            )
        case .faceLandmarks:
            return await perform(
                context: context,
                revisions: DetectFaceLandmarksRequest.supportedRevisions,
                handler: handler,
                request: DetectFaceLandmarksRequest.init,
                transform: faceLandmarksOutput
            )
        case .faceCaptureQuality:
            return await perform(
                context: context,
                revisions: DetectFaceCaptureQualityRequest.supportedRevisions,
                handler: handler,
                request: DetectFaceCaptureQualityRequest.init,
                transform: faceQualityOutput
            )
        case .animalBodyPose:
            return await perform(
                context: context,
                revisions: DetectAnimalBodyPoseRequest.supportedRevisions,
                handler: handler,
                request: DetectAnimalBodyPoseRequest.init,
                transform: animalPoseOutput
            )
        case .foregroundInstanceMask:
            return await perform(
                context: context,
                revisions: GenerateForegroundInstanceMaskRequest.supportedRevisions,
                handler: handler,
                request: GenerateForegroundInstanceMaskRequest.init,
                transform: instanceMaskOutput
            )
        case .personInstanceMask:
            return await perform(
                context: context,
                revisions: GeneratePersonInstanceMaskRequest.supportedRevisions,
                handler: handler,
                request: GeneratePersonInstanceMaskRequest.init,
                transform: instanceMaskOutput
            )
        case .personSegmentation:
            return await perform(
                context: context,
                revisions: GeneratePersonSegmentationRequest.supportedRevisions,
                handler: handler,
                request: { GeneratePersonSegmentationRequest($0) },
                transform: personSegmentationOutput
            )
        case .imageAesthetics:
            return await perform(
                context: context,
                revisions: CalculateImageAestheticsScoresRequest.supportedRevisions,
                handler: handler,
                request: CalculateImageAestheticsScoresRequest.init,
                transform: aestheticsOutput
            )
        case .attentionSaliency:
            return await perform(
                context: context,
                revisions: GenerateAttentionBasedSaliencyImageRequest.supportedRevisions,
                handler: handler,
                request: GenerateAttentionBasedSaliencyImageRequest.init,
                transform: saliencyOutput
            )
        case .objectnessSaliency:
            return await perform(
                context: context,
                revisions: GenerateObjectnessBasedSaliencyImageRequest.supportedRevisions,
                handler: handler,
                request: GenerateObjectnessBasedSaliencyImageRequest.init,
                transform: saliencyOutput
            )
        case .lensSmudgeDetection:
            guard #available(macOS 26.0, iOS 26.0, *) else { return .unsupported }
            return await perform(
                context: context,
                revisions: DetectLensSmudgeRequest.supportedRevisions,
                handler: handler,
                request: DetectLensSmudgeRequest.init,
                transform: lensSmudgeOutput
            )
        case .humanBodyPose:
            return await perform(
                context: context,
                revisions: DetectHumanBodyPoseRequest.supportedRevisions,
                handler: handler,
                request: DetectHumanBodyPoseRequest.init,
                transform: humanPoseOutput
            )
        case .humanHandPose:
            return await perform(
                context: context,
                revisions: DetectHumanHandPoseRequest.supportedRevisions,
                handler: handler,
                request: DetectHumanHandPoseRequest.init,
                transform: handPoseOutput
            )
        case .humanBodyPose3D:
            return await perform(
                context: context,
                revisions: DetectHumanBodyPose3DRequest.supportedRevisions,
                handler: handler,
                request: { DetectHumanBodyPose3DRequest($0) },
                transform: humanPose3DOutput
            )
        case .contours:
            return await perform(
                context: context,
                revisions: DetectContoursRequest.supportedRevisions,
                handler: handler,
                request: DetectContoursRequest.init,
                transform: contoursOutput
            )
        case .horizon:
            return await perform(
                context: context,
                revisions: DetectHorizonRequest.supportedRevisions,
                handler: handler,
                request: DetectHorizonRequest.init,
                transform: horizonOutput
            )
        case .rectangles:
            return await perform(
                context: context,
                revisions: DetectRectanglesRequest.supportedRevisions,
                handler: handler,
                request: DetectRectanglesRequest.init,
                transform: rectangleOutput
            )
        case .textRectangles:
            return await perform(
                context: context,
                revisions: DetectTextRectanglesRequest.supportedRevisions,
                handler: handler,
                request: DetectTextRectanglesRequest.init,
                transform: textRectangleOutput
            )
        case .textRecognition, .documentRecognition, .barcodeDetection:
            return .permanentFailure(.invalidExecutorResult)
        case .trajectories, .pairwiseOpticalFlow, .opticalFlow, .objectTracking, .rectangleTracking,
            .translationalImageRegistration, .homographicImageRegistration,
            .iterativeSegmentation:
            return .unsupported
        }
    }

    static func perform<Request: VisionRequest, Revision>(
        context: MLNativeResultContext,
        revisions: [Revision],
        handler: ImageRequestHandler,
        request: (Revision) -> Request,
        transform: (Request.Result, MLNativeResultContext) throws -> MLDerivedPipelineOutput?
    ) async -> ArtifactAnalysisResult {
        guard
            let revision = revisions.first(where: {
                String(describing: $0) == context.requestRevision
            })
        else {
            return .unsupported
        }
        do {
            let observation = try await handler.perform(request(revision))
            guard let output = try transform(observation, context) else { return .completedEmpty }
            return .completed(output)
        } catch is CancellationError {
            return .retryableFailure(.analysisFailed)
        } catch is MLAnalysisContractError {
            return .permanentFailure(.invalidArtifactContract)
        } catch {
            return .retryableFailure(.analysisFailed)
        }
    }

    static func documentSegmentationOutput(
        _ observation: DetectedDocumentObservation?,
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        guard let observation, let bounds = normalizedRect(observation.boundingBox) else { return nil }
        let region = MLDetectedRegion(
            label: "document",
            species: nil,
            confidence: observation.confidence,
            bounds: bounds
        )
        return try encodedOutput(
            MLGeometryArtifact(context: context, regions: [region]),
            searchableText: []
        )
    }

    static func classificationOutput(
        _ observations: [ClassificationObservation],
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let limits = MLNativeArtifactLimits.libraryIndexing
        let classifications =
            observations
            .filter {
                !$0.identifier.isEmpty
                    && $0.confidence.isFinite
                    && $0.confidence >= limits.minimumClassificationConfidence
            }
            .prefix(limits.maximumClassifications)
            .map { MLClassificationObservation(identifier: $0.identifier, confidence: $0.confidence) }
        guard !classifications.isEmpty else { return nil }
        return try encodedOutput(
            MLNativeClassificationArtifact(context: context, classifications: classifications),
            searchableText: []
        )
    }

    static func animalOutput(
        _ observations: [RecognizedObjectObservation],
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let regions = observations.prefix(MLNativeArtifactLimits.libraryIndexing.maximumRegions).compactMap {
            observation -> MLDetectedRegion? in
            guard let label = observation.labels.first,
                let bounds = normalizedRect(observation.boundingBox)
            else { return nil }
            let identifier = label.identifier.lowercased()
            let species: MLRegionSpecies? =
                switch identifier {
                case "cat": .cat
                case "dog": .dog
                default: nil
                }
            return MLDetectedRegion(
                label: identifier,
                species: species,
                confidence: label.confidence,
                bounds: bounds
            )
        }
        guard !regions.isEmpty else { return nil }
        return try encodedOutput(
            MLRegionDetectionArtifact(context: context, regions: regions),
            searchableText: []
        )
    }

    static func humanOutput(
        _ observations: [HumanObservation],
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let regions = observations.prefix(MLNativeArtifactLimits.libraryIndexing.maximumRegions).compactMap {
            observation -> MLDetectedRegion? in
            guard let bounds = normalizedRect(observation.boundingBox) else { return nil }
            return MLDetectedRegion(
                label: "human",
                species: .human,
                confidence: observation.confidence,
                bounds: bounds,
                metrics: ["upperBodyOnly": observation.isUpperBodyOnly ? 1 : 0]
            )
        }
        guard !regions.isEmpty else { return nil }
        return try encodedOutput(
            MLRegionDetectionArtifact(context: context, regions: regions),
            searchableText: []
        )
    }

    static func featurePrintOutput(
        _ observation: FeaturePrintObservation,
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let elementType: MLFeaturePrintElementType =
            switch observation.elementType {
            case .float: .float32
            case .double: .double
            @unknown default: .unknown
            }
        return try encodedOutput(
            MLFeaturePrintArtifact(
                context: context,
                elementType: elementType,
                elementCount: observation.elementCount,
                data: observation.data
            ),
            searchableText: []
        )
    }

    static func faceRegionsOutput(
        _ observations: [FaceObservation],
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let regions = faceRegions(observations, includeLandmarks: false)
        guard !regions.isEmpty else { return nil }
        return try encodedOutput(
            MLRegionDetectionArtifact(context: context, regions: regions),
            searchableText: []
        )
    }

    static func faceLandmarksOutput(
        _ observations: [FaceObservation],
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let regions = faceRegions(observations, includeLandmarks: true).filter { !$0.landmarks.isEmpty }
        guard !regions.isEmpty else { return nil }
        return try encodedOutput(
            MLRegionDetectionArtifact(context: context, regions: regions),
            searchableText: []
        )
    }

    static func faceQualityOutput(
        _ observations: [FaceObservation],
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let scores = observations.compactMap(\.captureQuality?.score).filter(\.isFinite)
        guard !scores.isEmpty else { return nil }
        return try encodedOutput(
            MLQualityArtifact(
                context: context,
                quality: scores.max(),
                metrics: [
                    "faceCount": Float(scores.count),
                    "meanCaptureQuality": scores.reduce(0, +) / Float(scores.count),
                ]
            ),
            searchableText: []
        )
    }

    static func faceRegions(
        _ observations: [FaceObservation],
        includeLandmarks: Bool
    ) -> [MLDetectedRegion] {
        observations.prefix(MLNativeArtifactLimits.libraryIndexing.maximumRegions).compactMap {
            observation -> MLDetectedRegion? in
            guard let bounds = normalizedRect(observation.boundingBox) else { return nil }
            var metrics: [String: Float] = [
                "rollDegrees": Float(observation.roll.converted(to: .degrees).value),
                "yawDegrees": Float(observation.yaw.converted(to: .degrees).value),
                "pitchDegrees": Float(observation.pitch.converted(to: .degrees).value),
            ]
            if let quality = observation.captureQuality?.score { metrics["captureQuality"] = quality }
            let landmarks: [MLRegionLandmark]
            if includeLandmarks, let points = observation.landmarks?.allPoints.points {
                landmarks = points.prefix(MLNativeArtifactLimits.libraryIndexing.maximumLandmarksPerRegion)
                    .enumerated().compactMap { index, point in
                        try? MLRegionLandmark(
                            identifier: "face-point-\(index)",
                            x: Double(point.x),
                            y: Double(point.y),
                            confidence: observation.confidence
                        )
                    }
            } else {
                landmarks = []
            }
            return MLDetectedRegion(
                label: "face",
                species: .human,
                confidence: observation.confidence,
                bounds: bounds,
                landmarks: landmarks,
                metrics: metrics
            )
        }
    }

    static func animalPoseOutput(
        _ observations: [AnimalBodyPoseObservation],
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let regions = observations.prefix(MLNativeArtifactLimits.libraryIndexing.maximumRegions).compactMap {
            observation -> MLDetectedRegion? in
            let landmarks = observation.allJoints().values.sorted { $0.jointName < $1.jointName }
                .prefix(MLNativeArtifactLimits.libraryIndexing.maximumLandmarksPerRegion)
                .compactMap { joint in
                    try? MLRegionLandmark(
                        identifier: joint.jointName,
                        x: Double(joint.location.x),
                        y: Double(joint.location.y),
                        confidence: joint.confidence
                    )
                }
            return poseRegion(
                label: "animal-pose",
                species: nil,
                confidence: observation.confidence,
                landmarks: landmarks
            )
        }
        guard !regions.isEmpty else { return nil }
        return try encodedOutput(
            MLRegionDetectionArtifact(context: context, regions: regions),
            searchableText: []
        )
    }

    static func humanPoseOutput(
        _ observations: [HumanBodyPoseObservation],
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let regions = observations.prefix(MLNativeArtifactLimits.libraryIndexing.maximumRegions).compactMap {
            observation -> MLDetectedRegion? in
            let landmarks = observation.allJoints().values.sorted { $0.jointName < $1.jointName }
                .prefix(MLNativeArtifactLimits.libraryIndexing.maximumLandmarksPerRegion)
                .compactMap { joint in
                    try? MLRegionLandmark(
                        identifier: joint.jointName,
                        x: Double(joint.location.x),
                        y: Double(joint.location.y),
                        confidence: joint.confidence
                    )
                }
            return poseRegion(
                label: "human-pose",
                species: .human,
                confidence: observation.confidence,
                landmarks: landmarks
            )
        }
        guard !regions.isEmpty else { return nil }
        return try encodedOutput(
            MLRegionDetectionArtifact(context: context, regions: regions),
            searchableText: []
        )
    }

    static func handPoseOutput(
        _ observations: [HumanHandPoseObservation],
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let regions = observations.prefix(MLNativeArtifactLimits.libraryIndexing.maximumRegions).compactMap {
            observation -> MLDetectedRegion? in
            let landmarks = observation.allJoints().values.sorted { $0.jointName < $1.jointName }
                .prefix(MLNativeArtifactLimits.libraryIndexing.maximumLandmarksPerRegion)
                .compactMap { joint in
                    try? MLRegionLandmark(
                        identifier: joint.jointName,
                        x: Double(joint.location.x),
                        y: Double(joint.location.y),
                        confidence: joint.confidence
                    )
                }
            var metrics: [String: Float] = [:]
            if let chirality = observation.chirality {
                metrics["leftChirality"] = chirality == .left ? 1 : 0
            }
            return poseRegion(
                label: "hand-pose",
                species: .human,
                confidence: observation.confidence,
                landmarks: landmarks,
                metrics: metrics
            )
        }
        guard !regions.isEmpty else { return nil }
        return try encodedOutput(
            MLRegionDetectionArtifact(context: context, regions: regions),
            searchableText: []
        )
    }

    static func humanPose3DOutput(
        _ observations: [HumanBodyPose3DObservation],
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let regions = observations.prefix(MLNativeArtifactLimits.libraryIndexing.maximumRegions).compactMap {
            observation -> MLDetectedRegion? in
            let names = observation.availableJointNames.sorted { $0.rawValue < $1.rawValue }
                .prefix(MLNativeArtifactLimits.libraryIndexing.maximumLandmarksPerRegion)
            let landmarks = names.compactMap { name -> MLRegionLandmark? in
                let point = observation.pointInImage(for: name)
                return try? MLRegionLandmark(
                    identifier: name.rawValue,
                    x: Double(point.x),
                    y: Double(point.y),
                    confidence: observation.confidence
                )
            }
            return poseRegion(
                label: "human-pose-3d",
                species: .human,
                confidence: observation.confidence,
                landmarks: landmarks,
                metrics: ["bodyHeightMeters": Float(observation.bodyHeight.converted(to: .meters).value)]
            )
        }
        guard !regions.isEmpty else { return nil }
        return try encodedOutput(
            MLRegionDetectionArtifact(context: context, regions: regions),
            searchableText: []
        )
    }

    static func poseRegion(
        label: String,
        species: MLRegionSpecies?,
        confidence: Float,
        landmarks: [MLRegionLandmark],
        metrics: [String: Float] = [:]
    ) -> MLDetectedRegion? {
        guard !landmarks.isEmpty,
            let minX = landmarks.map(\.x).min(), let maxX = landmarks.map(\.x).max(),
            let minY = landmarks.map(\.y).min(), let maxY = landmarks.map(\.y).max(),
            let bounds = try? MLNormalizedRect(
                x: minX,
                y: minY,
                width: maxX - minX,
                height: maxY - minY
            )
        else { return nil }
        return MLDetectedRegion(
            label: label,
            species: species,
            confidence: confidence,
            bounds: bounds,
            landmarks: landmarks,
            metrics: metrics
        )
    }

    static func instanceMaskOutput(
        _ observation: InstanceMaskObservation?,
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        guard let observation else { return nil }
        let side = MLNativeArtifactLimits.libraryIndexing.maskSampleSide
        var samplesByInstance: [Int: [(x: Int, y: Int)]] = [:]
        var coveredSamples = 0
        for y in 0..<side {
            for x in 0..<side {
                let point = NormalizedPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(side),
                    y: (CGFloat(y) + 0.5) / CGFloat(side)
                )
                let instances = observation.instanceAtPoint(point)
                guard !instances.isEmpty else { continue }
                coveredSamples += 1
                for instance in instances { samplesByInstance[instance, default: []].append((x, y)) }
            }
        }
        let totalSamples = side * side
        let regions = samplesByInstance.keys.sorted()
            .prefix(MLNativeArtifactLimits.libraryIndexing.maximumRegions)
            .compactMap { instance -> MLDetectedRegion? in
                guard let samples = samplesByInstance[instance], !samples.isEmpty,
                    let minX = samples.map(\.x).min(), let maxX = samples.map(\.x).max(),
                    let minY = samples.map(\.y).min(), let maxY = samples.map(\.y).max(),
                    let bounds = try? MLNormalizedRect(
                        x: Double(minX) / Double(side),
                        y: Double(minY) / Double(side),
                        width: Double(maxX - minX + 1) / Double(side),
                        height: Double(maxY - minY + 1) / Double(side)
                    )
                else { return nil }
                return MLDetectedRegion(
                    label: context.analysisKind == .personInstanceMask ? "person-instance" : "foreground-instance",
                    species: context.analysisKind == .personInstanceMask ? .human : nil,
                    confidence: observation.confidence,
                    bounds: bounds,
                    metrics: ["coverageFraction": Float(samples.count) / Float(totalSamples)]
                )
            }
        return try encodedOutput(
            MLMaskSummaryArtifact(
                context: context,
                format: .label8,
                instanceCount: observation.allInstances.count,
                coverageFraction: Float(coveredSamples) / Float(totalSamples),
                regions: regions
            ),
            searchableText: []
        )
    }

    static func personSegmentationOutput(
        _ observation: PixelBufferObservation,
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let side = MLNativeArtifactLimits.libraryIndexing.maskSampleSide
        var covered: [(x: Int, y: Int)] = []
        for y in 0..<side {
            for x in 0..<side {
                let point = NormalizedPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(side),
                    y: (CGFloat(y) + 0.5) / CGFloat(side)
                )
                if observation.pixel(at: point) >= 0.5 { covered.append((x, y)) }
            }
        }
        guard !covered.isEmpty else { return nil }
        let totalSamples = side * side
        let minX = covered.map(\.x).min() ?? 0
        let maxX = covered.map(\.x).max() ?? 0
        let minY = covered.map(\.y).min() ?? 0
        let maxY = covered.map(\.y).max() ?? 0
        let bounds = try MLNormalizedRect(
            x: Double(minX) / Double(side),
            y: Double(minY) / Double(side),
            width: Double(maxX - minX + 1) / Double(side),
            height: Double(maxY - minY + 1) / Double(side)
        )
        let coverage = Float(covered.count) / Float(totalSamples)
        let region = MLDetectedRegion(
            label: "person-segmentation",
            species: .human,
            confidence: observation.confidence,
            bounds: bounds,
            metrics: ["coverageFraction": coverage]
        )
        return try encodedOutput(
            MLMaskSummaryArtifact(
                context: context,
                format: .alpha8,
                instanceCount: 1,
                coverageFraction: coverage,
                regions: [region]
            ),
            searchableText: []
        )
    }

    static func aestheticsOutput(
        _ observation: ImageAestheticsScoresObservation,
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        try encodedOutput(
            MLQualityArtifact(
                context: context,
                aesthetics: observation.overallScore,
                metrics: [
                    "confidence": observation.confidence,
                    "utility": observation.isUtility ? 1 : 0,
                ]
            ),
            searchableText: []
        )
    }

    @available(macOS 26.0, iOS 26.0, *)
    static func lensSmudgeOutput(
        _ observation: SmudgeObservation,
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        try encodedOutput(
            MLQualityArtifact(
                context: context,
                quality: observation.confidence,
                metrics: ["smudgeConfidence": observation.confidence]
            ),
            searchableText: []
        )
    }

    static func saliencyOutput(
        _ observation: SaliencyImageObservation,
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let regions = observation.salientObjects
            .prefix(MLNativeArtifactLimits.libraryIndexing.maximumRegions)
            .compactMap { rectangle -> MLDetectedRegion? in
                guard let bounds = normalizedRect(rectangle.boundingBox) else { return nil }
                return MLDetectedRegion(
                    label: context.analysisKind == .attentionSaliency
                        ? "attention-saliency" : "objectness-saliency",
                    species: nil,
                    confidence: rectangle.confidence,
                    bounds: bounds
                )
            }
        guard !regions.isEmpty else { return nil }
        let coverage = min(
            1,
            regions.reduce(Float.zero) {
                $0 + Float($1.bounds.width * $1.bounds.height)
            })
        return try encodedOutput(
            MLSaliencyArtifact(
                context: context,
                confidence: observation.confidence,
                coverageFraction: coverage,
                salientRegions: regions
            ),
            searchableText: []
        )
    }

    static func contoursOutput(
        _ observation: ContoursObservation,
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        guard observation.contourCount > 0 else { return nil }
        return try encodedOutput(
            MLGeometryArtifact(
                context: context,
                pointCount: 0,
                metrics: [
                    "confidence": observation.confidence,
                    "contourCount": Float(observation.contourCount),
                    "topLevelContourCount": Float(observation.topLevelContours.count),
                ]
            ),
            searchableText: []
        )
    }

    static func horizonOutput(
        _ observation: HorizonObservation?,
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        guard let observation else { return nil }
        return try encodedOutput(
            MLGeometryArtifact(
                context: context,
                metrics: [
                    "angleDegrees": Float(observation.angle.converted(to: .degrees).value),
                    "confidence": observation.confidence,
                ]
            ),
            searchableText: []
        )
    }

    static func rectangleOutput(
        _ observations: [RectangleObservation],
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let regions = observations.prefix(MLNativeArtifactLimits.libraryIndexing.maximumRegions).compactMap {
            observation -> MLDetectedRegion? in
            guard let bounds = normalizedRect(observation.boundingBox) else { return nil }
            return MLDetectedRegion(
                label: "rectangle",
                species: nil,
                confidence: observation.confidence,
                bounds: bounds
            )
        }
        guard !regions.isEmpty else { return nil }
        return try encodedOutput(
            MLGeometryArtifact(context: context, regions: regions),
            searchableText: []
        )
    }

    static func textRectangleOutput(
        _ observations: [TextObservation],
        context: MLNativeResultContext
    ) throws -> MLDerivedPipelineOutput? {
        let regions = observations.prefix(MLNativeArtifactLimits.libraryIndexing.maximumRegions).compactMap {
            observation -> MLDetectedRegion? in
            guard let bounds = normalizedRect(observation.boundingBox) else { return nil }
            return MLDetectedRegion(
                label: "text-region",
                species: nil,
                confidence: observation.confidence,
                bounds: bounds,
                metrics: ["characterBoxCount": Float(observation.characterBoxes?.count ?? 0)]
            )
        }
        guard !regions.isEmpty else { return nil }
        return try encodedOutput(
            MLGeometryArtifact(context: context, regions: regions),
            searchableText: []
        )
    }
}

/// Source-compatible name for callers compiled before the executor grew beyond OCR/document work.
/// There remains exactly one actor, scheduler path, decode, and persistence pipeline.

private enum AppleVisionExecutorError: Error {
    case unsupportedRevision
}
