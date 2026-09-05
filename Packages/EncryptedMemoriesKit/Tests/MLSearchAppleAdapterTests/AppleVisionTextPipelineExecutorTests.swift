import CoreGraphics
import CoreImage
import CoreText
import Foundation
import MLSearchCore
import PhotosCore
import Testing
import Vision

@testable import MLSearchAppleAdapter

@Suite struct AppleVisionPipelineExecutorTests {
    @Test func backgroundDevicePolicyUsesOnlySupportedCPUStages() throws {
        let request = DetectTextRectanglesRequest()
        let stages = request.supportedComputeStageDevices
        let cpuAvailable =
            !stages.isEmpty
            && stages.values.allSatisfy { devices in
                devices.contains { if case .cpu = $0 { true } else { false } }
            }
        if cpuAvailable {
            let configured = try AppleVisionComputePolicy.prepare(request, requiresCPUOnly: true)
            for stage in stages.keys {
                guard case .cpu = configured.computeDevice(for: stage) else {
                    Issue.record("Every background Vision stage must use a supported CPU")
                    continue
                }
            }
        } else {
            #expect(throws: AppleVisionComputePolicy.UnavailableInBackground.self) {
                try AppleVisionComputePolicy.prepare(request, requiresCPUOnly: true)
            }
        }
        #expect(try AppleVisionComputePolicy.prepare(request, requiresCPUOnly: false) == request)
    }

    @Test func backgroundUnavailableStagesStayPendingInsteadOfBecomingUnsupported() async throws {
        let executor = AppleVisionPipelineExecutor(
            imageSource: CountingVisionImageSource(outcome: .image(try sourceImage())),
            resultAnalyzer: { _, contexts in
                Dictionary(uniqueKeysWithValues: contexts.keys.map { ($0, .suspended) })
            })
        let results = await executor.execute(try makePlan(kinds: [.textRecognition, .barcodeDetection]))
        #expect(results.allSatisfy { $0.outcome == .suspended(.resourcePolicy) })
        #expect(AppleVisionPipelineExecutor.routingDecision(for: .suspended) == .run)
    }

    @Test func oneSourceImageFeedsIndependentTextAndBarcodeStages() async throws {
        let imageSource = CountingVisionImageSource(outcome: .image(try sourceImage()))
        let probe = VisionAnalysisProbe()
        let executor = AppleVisionPipelineExecutor(imageSource: imageSource) { source, contexts in
            await probe.analyze(source: source, contexts: contexts)
        }
        let plan = try makePlan(kinds: [.textRecognition, .barcodeDetection])

        let results = await executor.execute(plan)

        #expect(await imageSource.calls == 1)
        #expect(await probe.calls == 1)
        #expect(results.count == 2)
        #expect(results.allSatisfy { if case .completed = $0.outcome { true } else { false } })
    }

    @Test func missingOutputCompletesOnlyThatStageAsEmpty() async throws {
        let executor = AppleVisionPipelineExecutor(
            imageSource: CountingVisionImageSource(outcome: .image(try sourceImage()))
        ) { _, contexts in
            guard contexts[.textRecognition] != nil else { return [:] }
            return [
                .textRecognition: MLDerivedPipelineOutput(
                    payload: Data("text".utf8),
                    normalizedSearchTokens: ["text"]
                )
            ]
        }
        let results = await executor.execute(try makePlan(kinds: [.textRecognition, .barcodeDetection]))
        #expect(results.count == 2)
        #expect(results.contains { if case .completed = $0.outcome { true } else { false } })
        #expect(results.contains { $0.outcome == .completedEmpty })
    }

    @Test func dependentTextWorkRunsOnlyAfterPositiveRoutingEvidence() {
        #expect(
            AppleVisionPipelineExecutor.routingDecision(
                for: .completed(.init(payload: Data("region".utf8)))
            ) == .run)
        #expect(
            AppleVisionPipelineExecutor.routingDecision(
                for: .completedEmpty
            ) == .skip)
        #expect(
            AppleVisionPipelineExecutor.routingDecision(
                for: .retryableFailure(.analysisFailed)
            ) == .retry)
        #expect(
            AppleVisionPipelineExecutor.routingDecision(
                for: nil
            ) == .run)
    }

    @Test func unavailableCachedImageDefersAllStagesWithoutConsumingFailureBudget() async throws {
        let executor = AppleVisionPipelineExecutor(
            imageSource: CountingVisionImageSource(outcome: .transientFailure),
            analyze: { _, _ in
                Issue.record("Vision must not run without an image")
                return [:]
            }
        )
        let results = await executor.execute(try makePlan(kinds: [.textRecognition, .barcodeDetection]))
        #expect(
            results.allSatisfy {
                $0.outcome == .deferred(reason: .sourceNotResident, retryAfter: nil)
            })
    }

    @Test func structuredDocumentProducesIndependentSearchArtifactsWithoutFlatteningLayout() throws {
        let bounds = try MLNormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.3)
        let snapshot = AppleVisionPipelineExecutor.StructuredDocumentSnapshot(
            languages: ["de", "en"],
            text: [.init(text: "Rechnung Nummer 42", languages: ["de"], confidence: 0.98, bounds: bounds)],
            barcodes: [.init(payload: "INV-42", symbology: "qr", confidence: 1, bounds: bounds)],
            regions: [
                .init(
                    kind: .tableCell,
                    text: "Rechnung Nummer 42",
                    groupIndex: 0,
                    row: 1,
                    rowSpan: 2,
                    column: 3,
                    columnSpan: 1,
                    confidence: 0.98,
                    bounds: bounds
                )
            ]
        )
        let outputs = try AppleVisionPipelineExecutor.encodedDocumentOutputs(
            snapshot,
            contexts: try nativeContexts(kinds: [
                .textRecognition,
                .documentRecognition,
                .barcodeDetection,
            ])
        )

        #expect(
            Set(outputs.keys)
                == Set<MLNativeAnalysisKind>([
                    .textRecognition,
                    .documentRecognition,
                    .barcodeDetection,
                ]))
        #expect(outputs[.textRecognition]?.normalizedSearchTokens.contains("rechnung") == true)
        #expect(outputs[.documentRecognition]?.normalizedSearchTokens.contains("nummer") == true)
        #expect(Set(outputs[.barcodeDetection]?.normalizedSearchTokens ?? []) == ["inv", "42"])
        let payload = try #require(outputs[.documentRecognition]?.payload)
        let document = try JSONDecoder().decode(MLStructuredDocumentArtifact.self, from: payload)
        let cell = try #require(document.regions.first)
        #expect(cell.groupIndex == 0)
        #expect(cell.row == 1)
        #expect(cell.rowSpan == 2)
        #expect(cell.column == 3)
        #expect(cell.columnSpan == 1)
    }

    @Test func structuredDocumentBarcodeExtractionStaysRootBounded() throws {
        var sourceURL = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { sourceURL.deleteLastPathComponent() }
        sourceURL.append(path: "Sources/MLSearchAppleAdapter/AppleVisionTextPipelineExecutor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try #require(source.range(of: "private static func documentBarcodes("))
        let tail = source[start.lowerBound...]
        let end = try #require(
            tail.range(of: "\n    @available", range: tail.index(after: start.lowerBound)..<tail.endIndex))
        let implementation = tail[..<end.lowerBound]

        #expect(implementation.contains("document.barcodes"))
        #expect(!implementation.contains("cell.content"))
        #expect(!implementation.contains("item.content"))
        #expect(!implementation.contains("func collect"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_RUN_VISION_QUALIFICATION"] == "1"))
    func structuredDocumentQualificationFixture() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let imageSource = CountingVisionImageSource(
            outcome: .image(CoreMLSourceImage(cgImage: try qualificationDocumentImage()))
        )
        let executor = AppleVisionPipelineExecutor(imageSource: imageSource)
        let capabilitySnapshot = await AppleVisionCapabilityProvider().capabilitySnapshot()
        let revisions = Dictionary(
            uniqueKeysWithValues: capabilitySnapshot.capabilities.compactMap {
                capability -> (MLNativeAnalysisKind, String)? in
                capability.selectedRevision.map { (capability.kind, $0) }
            })
        let startedAt = ContinuousClock.now
        let results = await executor.execute(
            try makePlan(
                kinds: [
                    .textRecognition,
                    .documentRecognition,
                    .barcodeDetection,
                    .imageFeaturePrint,
                    .rectangles,
                    .imageClassification,
                    .imageAesthetics,
                ], revisions: revisions))
        let duration = ContinuousClock.now - startedAt
        let completedKinds = Set(
            results.compactMap { result -> MLNativeAnalysisKind? in
                guard case .completed = result.outcome,
                    case .native(_, let kind, _) = result.workItem.artifact.producer
                else { return nil }
                return kind
            })
        let payloadBytes = Dictionary(
            uniqueKeysWithValues: results.compactMap {
                result -> (String, Int)? in
                guard case .completed(let output) = result.outcome,
                    case .native(_, let kind, _) = result.workItem.artifact.producer
                else { return nil }
                return (kind.rawValue, output.payload.count)
            })

        #expect(await imageSource.calls == 1)
        #expect(completedKinds.contains(.documentRecognition))
        #expect(completedKinds.contains(.textRecognition))
        #expect(completedKinds.contains(.barcodeDetection))
        #expect(completedKinds.contains(.imageFeaturePrint))
        #expect(completedKinds.contains(.rectangles))
        print(
            "Vision document qualification: \(duration), decodes=1, "
                + "outputs=\(completedKinds.map(\.rawValue).sorted()), payloadBytes=\(payloadBytes)"
        )
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_RUN_VISION_QUALIFICATION"] == "1"))
    func boundedVisionBatchQualificationFixture() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let imageSource = CountingVisionImageSource(
            outcome: .image(CoreMLSourceImage(cgImage: try qualificationDocumentImage()))
        )
        let executor = AppleVisionPipelineExecutor(imageSource: imageSource)
        let capabilitySnapshot = await AppleVisionCapabilityProvider().capabilitySnapshot()
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "qualification",
            capabilitySnapshot: capabilitySnapshot
        )
        let expectedKinds: Set<MLNativeAnalysisKind> = Set(
            configuration.executionKey.artifacts.compactMap {
                guard case .native(_, let kind, _) = $0.producer else { return nil }
                return kind
            })
        let assetCount = 5
        let startedAt = Date()
        var payloadBytes = 0
        for index in 0..<assetCount {
            let results = await executor.execute(
                try makePlan(
                    configuration: configuration,
                    nodeID: "photo-\(index)"
                ))
            #expect(results.count == expectedKinds.count)
            let actualKinds: Set<MLNativeAnalysisKind> = Set(
                results.compactMap {
                    guard case .native(_, let kind, _) = $0.workItem.artifact.producer else { return nil }
                    return kind
                })
            #expect(actualKinds == expectedKinds)
            let unexpected = results.compactMap { result -> String? in
                switch result.outcome {
                case .completed, .completedEmpty:
                    return nil
                default:
                    guard case .native(_, let kind, _) = result.workItem.artifact.producer else {
                        return "unknown=\(String(describing: result.outcome))"
                    }
                    return "\(kind.rawValue)=\(String(describing: result.outcome))"
                }
            }
            if !unexpected.isEmpty {
                print("Vision qualification unexpected outcomes: \(unexpected.sorted())")
            }
            #expect(
                results.allSatisfy { result in
                    switch result.outcome {
                    case .completed(let output):
                        payloadBytes += output.payload.count
                        return true
                    case .completedEmpty:
                        return true
                    default:
                        return false
                    }
                })
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let assetsPerSecond = Double(assetCount) / elapsed

        #expect(await imageSource.calls == assetCount)
        print(
            "Vision batch qualification: assets=\(assetCount), stages=\(expectedKinds.count), seconds=\(elapsed), "
                + "assetsPerSecond=\(assetsPerSecond), decodes=\(await imageSource.calls), "
                + "payloadBytes=\(payloadBytes)"
        )
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_RUN_VISION_QUALIFICATION"] == "1"))
    func boundedConcurrentVisionQualificationFixture() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let imageSource = CountingVisionImageSource(
            outcome: .image(CoreMLSourceImage(cgImage: try qualificationDocumentImage()))
        )
        let executor = AppleVisionPipelineExecutor(imageSource: imageSource)
        let capabilitySnapshot = await AppleVisionCapabilityProvider().capabilitySnapshot()
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "qualification",
            capabilitySnapshot: capabilitySnapshot
        )
        let store = InMemoryMLDerivedPipelineStore()
        let assets = try (0..<6).map {
            try MLPipelineAssetRevision(
                uid: PhotoUID(volumeID: "volume", nodeID: "concurrent-\($0)"),
                sourceRevision: "photo"
            )
        }
        #expect(store.enqueue(assets, for: configuration.executionKey))

        let startedAt = Date()
        let outcome = await MLIndexRunner.runDerivedPass(
            key: configuration.executionKey,
            store: store,
            executor: executor,
            configuration: .init(
                chunkSize: assets.count,
                maximumConcurrentDerivedAssets: 3
            )
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(outcome.reason == .drained)
        #expect(outcome.progress.isComplete)
        #expect(await imageSource.calls == assets.count)
        print(
            "Vision concurrent qualification: assets=\(assets.count), "
                + "stages=\(configuration.executionKey.artifacts.count), seconds=\(elapsed), "
                + "assetsPerSecond=\(Double(assets.count) / elapsed), concurrency=3"
        )
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_RUN_VISION_QUALIFICATION"] == "1"))
    func legacyAndAdaptiveVisionPerformanceHarness() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let imageSource = CountingVisionImageSource(
            outcome: .image(CoreMLSourceImage(cgImage: try qualificationDocumentImage()))
        )
        let executor = AppleVisionPipelineExecutor(imageSource: imageSource)
        let capabilitySnapshot = await AppleVisionCapabilityProvider().capabilitySnapshot()
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "qualification",
            capabilitySnapshot: capabilitySnapshot
        )
        let concurrencyCeiling = MLNativeAnalysisResourcePolicy.maximumConcurrentAssets(
            capabilitySnapshot: capabilitySnapshot,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
        let assetCount = 32

        func measure(
            profile: MLIndexingCapacityProfile,
            maximumConcurrentAssets: Int,
            label: String
        ) async throws -> [Double] {
            var warmMeasurements: [Double] = []
            for iteration in 0..<4 {
                let store = InMemoryMLDerivedPipelineStore()
                let assets = try (0..<assetCount).map {
                    try MLPipelineAssetRevision(
                        uid: PhotoUID(volumeID: label, nodeID: "\(iteration)-\($0)"),
                        sourceRevision: "photo"
                    )
                }
                #expect(store.enqueue(assets, for: configuration.executionKey))
                let startedAt = ContinuousClock.now
                var outcome: MLDerivedPipelinePassOutcome
                repeat {
                    outcome = await MLIndexRunner.runDerivedPass(
                        key: configuration.executionKey,
                        store: store,
                        executor: executor,
                        configuration: .init(
                            chunkSize: assetCount,
                            maximumConcurrentDerivedAssets: maximumConcurrentAssets
                        ),
                        maximumAnalysisPlans: profile.nativeQuantumAssets
                    )
                } while outcome.reason == .workQuantumCompleted
                #expect(outcome.reason == .drained)
                let elapsed = seconds(startedAt.duration(to: ContinuousClock.now))
                if iteration > 0 {
                    warmMeasurements.append(Double(assetCount) / elapsed)
                }
            }
            return warmMeasurements
        }

        let legacy = try await measure(
            profile: .constrained,
            maximumConcurrentAssets: min(2, concurrencyCeiling),
            label: "legacy"
        )
        let adaptive = try await measure(
            profile: .sustained,
            maximumConcurrentAssets: concurrencyCeiling,
            label: "adaptive"
        )
        let legacyMedian = median(legacy)
        let adaptiveMedian = median(adaptive)
        let ratio = adaptiveMedian / legacyMedian
        print(
            "Vision profile qualification: ceiling=\(concurrencyCeiling), assets=\(assetCount), "
                + "legacyMedianAssetsPerSecond=\(legacyMedian), "
                + "adaptiveMedianAssetsPerSecond=\(adaptiveMedian), ratio=\(ratio)"
        )
        if concurrencyCeiling >= 3 {
            #expect(ratio >= 1.5)
        }
    }

    private func makePlan(
        configuration: MLNativeSearchConfiguration,
        nodeID: String
    ) throws -> MLAssetAnalysisPlan {
        let asset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: nodeID),
            sourceRevision: "photo"
        )
        let work = configuration.executionKey.artifacts
            .sorted { $0.stableNamespace < $1.stableNamespace }
            .map { MLDerivedPipelineWorkItem(asset: asset, artifact: $0) }
        return try MLAssetAnalysisPlan(asset: asset, workItems: work)
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private func makePlan(
        kinds: [MLNativeAnalysisKind],
        revisions: [MLNativeAnalysisKind: String] = [:],
        nodeID: String = "photo"
    ) throws -> MLAssetAnalysisPlan {
        let asset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: nodeID),
            sourceRevision: "photo"
        )
        let work = try kinds.map { kind in
            let output: MLAnalysisOutputDescriptor =
                switch kind {
                case .textRecognition: .recognizedText
                case .documentRecognition: .structuredDocument
                case .barcodeDetection: .barcodePayload
                case .imageFeaturePrint: .featurePrint
                case .rectangles: .geometry
                case .imageClassification: .classifications
                case .imageAesthetics: .qualityMetrics
                default: .recognizedText
                }
            let artifact = try MLDerivedArtifactIdentity(
                pipelineID: .nativeSearch,
                stageID: MLStageID(rawValue: kind.rawValue),
                producer: .native(
                    providerIdentifier: "apple.vision",
                    kind: kind,
                    requestRevision: revisions[kind] ?? "revision1"
                ),
                preprocessingRevision: MLNativeSearchConfiguration.preprocessingRevision,
                output: output,
                schemaEpoch: 1
            )
            return MLDerivedPipelineWorkItem(
                asset: asset,
                artifact: artifact
            )
        }
        return try MLAssetAnalysisPlan(asset: asset, workItems: work)
    }

    private func nativeContexts(
        kinds: [MLNativeAnalysisKind]
    ) throws -> [MLNativeAnalysisKind: MLNativeResultContext] {
        try Dictionary(
            uniqueKeysWithValues: kinds.map { kind in
                (
                    kind,
                    try MLNativeResultContext(
                        providerIdentifier: "apple.vision",
                        analysisKind: kind,
                        requestRevision: "revision1",
                        preprocessingRevision: MLNativeSearchConfiguration.preprocessingRevision,
                        schemaEpoch: 1
                    )
                )
            })
    }

    private func sourceImage() throws -> CoreMLSourceImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        return CoreMLSourceImage(cgImage: try #require(context.makeImage()))
    }

    private func qualificationDocumentImage() throws -> CGImage {
        let width = 1_200
        let height = 1_600
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
        context.setLineWidth(4)
        for x in [100, 600, 1_100] {
            context.move(to: CGPoint(x: x, y: 600))
            context.addLine(to: CGPoint(x: x, y: 1_050))
        }
        for y in [600, 750, 900, 1_050] {
            context.move(to: CGPoint(x: 100, y: y))
            context.addLine(to: CGPoint(x: 1_100, y: y))
        }
        context.strokePath()

        let text = """
            RECHNUNG 42

            Kunde: Encrypted Memories
            Datum: 15. Juli 2026

            Artikel                         Betrag
            Lokale OCR                      12,00 EUR
            Strukturierte Dokumente         30,00 EUR

            Gesamt                          42,00 EUR
            """
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 42, nil),
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1),
            ]
        )
        let frameSetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 120, y: 430, width: 960, height: 1_000), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(frameSetter, CFRange(), path, nil), context)

        let qrData = Data("ENCRYPTED-MEMORIES-TASK-04".utf8)
        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(qrData, forKey: "inputMessage")
            filter.setValue("H", forKey: "inputCorrectionLevel")
            if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
                let qr = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent)
            {
                context.interpolationQuality = .none
                context.draw(qr, in: CGRect(x: 820, y: 100, width: 260, height: 260))
            }
        }
        return try #require(context.makeImage())
    }
}

private actor CountingVisionImageSource: CoreMLImageSource {
    private let outcome: CoreMLImageSourceOutcome
    private(set) var calls = 0

    init(outcome: CoreMLImageSourceOutcome) { self.outcome = outcome }

    func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome {
        calls += 1
        return outcome
    }
}

private actor VisionAnalysisProbe {
    private(set) var calls = 0

    func analyze(
        source: CoreMLSourceImage,
        contexts: [MLNativeAnalysisKind: MLNativeResultContext]
    ) -> [MLNativeAnalysisKind: MLDerivedPipelineOutput] {
        calls += 1
        return Dictionary(
            uniqueKeysWithValues: contexts.keys.map { kind in
                (
                    kind,
                    MLDerivedPipelineOutput(
                        payload: Data(kind.rawValue.utf8),
                        normalizedSearchTokens: [kind.rawValue]
                    )
                )
            })
    }
}
