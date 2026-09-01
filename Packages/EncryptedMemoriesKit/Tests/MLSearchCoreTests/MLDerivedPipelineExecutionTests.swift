import Foundation
import PhotosCore
import Testing

@testable import MLSearchCore

@Suite struct MLDerivedPipelineExecutionTests {
    @Test func twoPipelinesAdvanceAndPurgeIndependently() async throws {
        let store = InMemoryMLDerivedPipelineStore()
        let nativeArtifact = try artifact(pipeline: .nativeSearch, stage: "ocr", revision: "revision3")
        let peopleArtifact = try artifact(pipeline: .people, stage: "faces", revision: "revision1")
        let nativeKey = try executionKey(pipeline: .nativeSearch, artifacts: [nativeArtifact])
        let peopleKey = try executionKey(pipeline: .people, artifacts: [peopleArtifact])
        let assets = try [asset("1"), asset("2")]
        #expect(store.enqueue(assets, for: nativeKey))
        #expect(store.enqueue(assets, for: peopleKey))

        let executor = RecordingExecutor { plan in
            plan.workItems.map {
                MLPipelineStageResult(
                    workItem: $0,
                    outcome: .completed(
                        .init(
                            payload: Data($0.artifact.stageID.rawValue.utf8),
                            normalizedSearchTokens: [$0.artifact.stageID.rawValue]
                        ))
                )
            }
        }
        let nativeOutcome = await MLIndexRunner.runDerivedPass(
            key: nativeKey,
            store: store,
            executor: executor,
            configuration: .init(chunkSize: 1)
        )

        #expect(nativeOutcome.reason == .drained)
        #expect(nativeOutcome.progress.completed == 2)
        #expect(store.progress(for: peopleKey).completed == 0)

        store.purge(artifact: nativeArtifact, accountIdentifier: nativeKey.accountIdentifier)
        #expect(store.progress(for: nativeKey).total == 0)
        #expect(store.progress(for: peopleKey).total == 2)
    }

    @Test func suspensionBeforeCommitLeavesWorkPending() async throws {
        let store = InMemoryMLDerivedPipelineStore()
        let artifact = try artifact(pipeline: .nativeSearch, stage: "ocr", revision: "revision3")
        let key = try executionKey(pipeline: .nativeSearch, artifacts: [artifact])
        let queuedAsset = try asset("1")
        #expect(store.enqueue([queuedAsset], for: key))

        let suspended = RecordingExecutor { plan in
            plan.workItems.map { .init(workItem: $0, outcome: .suspended(.userVisibleWork)) }
        }
        let first = await MLIndexRunner.runDerivedPass(key: key, store: store, executor: suspended)
        #expect(first.reason == .policySuspended)
        #expect(first.progress.completed == 0)
        #expect(first.progress.pending == 1)

        let completing = RecordingExecutor { plan in
            plan.workItems.map {
                .init(workItem: $0, outcome: .completed(.init(payload: Data("ok".utf8))))
            }
        }
        let second = await MLIndexRunner.runDerivedPass(key: key, store: store, executor: completing)
        #expect(second.reason == .drained)
        #expect(second.progress.completed == 1)
    }

    @Test func committedOutputDoesNotExecuteAgain() async throws {
        let store = InMemoryMLDerivedPipelineStore()
        let artifact = try artifact(pipeline: .nativeSearch, stage: "ocr", revision: "revision3")
        let key = try executionKey(pipeline: .nativeSearch, artifacts: [artifact])
        let queuedAsset = try asset("1")
        #expect(store.enqueue([queuedAsset], for: key))
        let executor = RecordingExecutor { plan in
            plan.workItems.map {
                .init(workItem: $0, outcome: .completed(.init(payload: Data("once".utf8))))
            }
        }

        _ = await MLIndexRunner.runDerivedPass(key: key, store: store, executor: executor)
        _ = await MLIndexRunner.runDerivedPass(key: key, store: store, executor: executor)

        #expect(await executor.executionCount == 1)
        #expect(store.output(for: uid("1"), artifact: artifact, accountIdentifier: "account") != nil)
    }

    @Test func changedSourceRevisionReopensOnlyThatAsset() async throws {
        let store = InMemoryMLDerivedPipelineStore()
        let artifact = try artifact(pipeline: .nativeSearch, stage: "ocr", revision: "revision3")
        let key = try executionKey(pipeline: .nativeSearch, artifacts: [artifact])
        let initialAssets = try [asset("1"), asset("2")]
        #expect(store.enqueue(initialAssets, for: key))
        let executor = RecordingExecutor { plan in
            plan.workItems.map {
                .init(workItem: $0, outcome: .completed(.init(payload: Data("ok".utf8))))
            }
        }
        _ = await MLIndexRunner.runDerivedPass(key: key, store: store, executor: executor)

        #expect(
            store.enqueue(
                [
                    try MLPipelineAssetRevision(uid: uid("1"), sourceRevision: "source-v2")
                ], for: key))
        let progress = store.progress(for: key)
        #expect(progress.completed == 1)
        #expect(progress.pending == 1)
    }

    @Test func optionalStageFailureDoesNotDiscardIndependentOutput() async throws {
        let store = InMemoryMLDerivedPipelineStore()
        let ocr = try artifact(pipeline: .nativeSearch, stage: "ocr", revision: "revision3")
        let barcode = try artifact(pipeline: .nativeSearch, stage: "barcode", revision: "revision1")
        let key = try executionKey(pipeline: .nativeSearch, artifacts: [ocr, barcode])
        let queuedAsset = try asset("1")
        #expect(store.enqueue([queuedAsset], for: key))
        let executor = RecordingExecutor { plan in
            plan.workItems.map { item in
                if item.artifact == barcode {
                    return .init(
                        workItem: item,
                        outcome: .retryableFailure(reason: .analysisFailed, retryAfter: nil)
                    )
                }
                return .init(
                    workItem: item,
                    outcome: .completed(
                        .init(
                            payload: Data("hello".utf8),
                            normalizedSearchTokens: ["hello"]
                        ))
                )
            }
        }
        let outcome = await MLIndexRunner.runDerivedPass(
            key: key,
            store: store,
            executor: executor,
            configuration: .init(chunkSize: 1, retryDelay: 60, maxRetryAttempts: 3),
            now: { Date(timeIntervalSince1970: 100) }
        )

        #expect(outcome.reason == .retryPending)
        #expect(outcome.progress.completed == 1)
        #expect(outcome.progress.retryPending == 1)
        #expect(store.output(for: uid("1"), artifact: ocr, accountIdentifier: "account") != nil)
        #expect(store.output(for: uid("1"), artifact: barcode, accountIdentifier: "account") == nil)
    }

    @Test func retryBudgetSettlesUnavailableInputTruthfully() async throws {
        let store = InMemoryMLDerivedPipelineStore()
        let artifact = try artifact(pipeline: .nativeSearch, stage: "ocr", revision: "revision3")
        let key = try executionKey(pipeline: .nativeSearch, artifacts: [artifact])
        let queuedAsset = try asset("1")
        #expect(store.enqueue([queuedAsset], for: key))
        let executor = RecordingExecutor { plan in
            plan.workItems.map {
                .init(workItem: $0, outcome: .retryableFailure(reason: .analysisFailed, retryAfter: nil))
            }
        }
        let firstClock = Date(timeIntervalSince1970: 100)
        let configuration = MLIndexRunner.Configuration(chunkSize: 1, retryDelay: 1, maxRetryAttempts: 2)
        let first = await MLIndexRunner.runDerivedPass(
            key: key,
            store: store,
            executor: executor,
            configuration: configuration,
            now: { firstClock }
        )
        #expect(first.progress.retryPending == 1)

        let secondClock = firstClock.addingTimeInterval(2)
        let second = await MLIndexRunner.runDerivedPass(
            key: key,
            store: store,
            executor: executor,
            configuration: configuration,
            now: { secondClock }
        )
        #expect(second.reason == .drained)
        #expect(second.progress.permanentFailure == 1)
        #expect(second.progress.isComplete)
    }

    @Test func sourceResidencyDeferralNeverConsumesRetryBudget() async throws {
        let store = InMemoryMLDerivedPipelineStore()
        let artifact = try artifact(pipeline: .nativeSearch, stage: "ocr", revision: "revision3")
        let key = try executionKey(pipeline: .nativeSearch, artifacts: [artifact])
        #expect(store.enqueue([try asset("waiting")], for: key))
        let executor = RecordingExecutor { plan in
            plan.workItems.map {
                .init(workItem: $0, outcome: .deferred(reason: .sourceNotResident, retryAfter: nil))
            }
        }
        let configuration = MLIndexRunner.Configuration(chunkSize: 1, retryDelay: 0, maxRetryAttempts: 1)

        for second in 0..<3 {
            let outcome = await MLIndexRunner.runDerivedPass(
                key: key,
                store: store,
                executor: executor,
                configuration: configuration,
                now: { Date(timeIntervalSince1970: Double(second)) }
            )
            #expect(outcome.progress.retryPending == 1)
            #expect(outcome.progress.permanentFailure == 0)
        }
        #expect(store.nextWorkBatch(for: key, limit: 1, now: .distantFuture).first?.attempts == 0)
    }

    @Test func searchRequiresEveryNormalizedTokenAndKeepsAccountsIsolated() async throws {
        let store = InMemoryMLDerivedPipelineStore()
        let artifact = try artifact(pipeline: .nativeSearch, stage: "ocr", revision: "revision3")
        let firstKey = try executionKey(account: "account", pipeline: .nativeSearch, artifacts: [artifact])
        let secondKey = try executionKey(account: "other", pipeline: .nativeSearch, artifacts: [artifact])
        let firstAsset = try asset("1")
        let secondAsset = try asset("2")
        #expect(store.enqueue([firstAsset], for: firstKey))
        #expect(store.enqueue([secondAsset], for: secondKey))
        let executor = RecordingExecutor { plan in
            plan.workItems.map {
                .init(
                    workItem: $0,
                    outcome: .completed(
                        .init(
                            payload: Data("display".utf8),
                            normalizedSearchTokens: ["hallo", "welt"]
                        )))
            }
        }
        _ = await MLIndexRunner.runDerivedPass(key: firstKey, store: store, executor: executor)
        _ = await MLIndexRunner.runDerivedPass(key: secondKey, store: store, executor: executor)

        #expect(store.search(normalizedTokens: ["hallo", "welt"], in: firstKey, limit: 10).map(\.uid) == [uid("1")])
        #expect(store.search(normalizedTokens: ["hallo", "missing"], in: firstKey, limit: 10).isEmpty)
    }

    @Test func allScopeRequiresEveryTokenAcrossIndependentArtifacts() async throws {
        let store = InMemoryMLDerivedPipelineStore()
        let ocr = try artifact(pipeline: .nativeSearch, stage: "ocr", revision: "revision3")
        let barcode = try artifact(pipeline: .nativeSearch, stage: "barcode", revision: "revision4")
        let key = try executionKey(pipeline: .nativeSearch, artifacts: [ocr, barcode])
        let queuedAsset = try asset("1")
        #expect(store.enqueue([queuedAsset], for: key))
        let executor = RecordingExecutor { plan in
            plan.workItems.map { item in
                let tokens =
                    item.artifact == ocr
                    ? ["shared", "invoice"]
                    : ["shared", "qr42"]
                return .init(
                    workItem: item,
                    outcome: .completed(.init(payload: Data(), normalizedSearchTokens: tokens))
                )
            }
        }
        _ = await MLIndexRunner.runDerivedPass(key: key, store: store, executor: executor)

        #expect(
            store.search(normalizedTokens: ["invoice", "qr42"], in: key, limit: 10).map(\.uid) == [queuedAsset.uid])
        #expect(store.search(normalizedTokens: ["shared", "missing"], in: key, limit: 10).isEmpty)
    }

    @Test func derivedRunnerHonorsBoundedAssetConcurrency() async throws {
        let store = InMemoryMLDerivedPipelineStore()
        let artifact = try artifact(pipeline: .nativeSearch, stage: "ocr", revision: "revision3")
        let key = try executionKey(pipeline: .nativeSearch, artifacts: [artifact])
        let assets = try (0..<8).map { try asset("\($0)") }
        #expect(store.enqueue(assets, for: key))
        let executor = ConcurrencyMeasuringExecutor()

        let outcome = await MLIndexRunner.runDerivedPass(
            key: key,
            store: store,
            executor: executor,
            configuration: .init(
                chunkSize: 8,
                maximumConcurrentDerivedAssets: 3
            )
        )

        #expect(outcome.reason == .drained)
        #expect(await executor.maximumObserved == 3)
        #expect(await executor.executionCount == assets.count)
    }

    @Test func derivedQuantumStopsAfterBoundedAssetsAndResumesImmediately() async throws {
        let store = InMemoryMLDerivedPipelineStore()
        let artifact = try artifact(pipeline: .nativeSearch, stage: "ocr", revision: "revision3")
        let key = try executionKey(pipeline: .nativeSearch, artifacts: [artifact])
        let assets = try (0..<10).map { try asset("\($0)") }
        #expect(store.enqueue(assets, for: key))
        let executor = RecordingExecutor { plan in
            plan.workItems.map {
                .init(workItem: $0, outcome: .completed(.init(payload: Data("ok".utf8))))
            }
        }

        let first = await MLIndexRunner.runDerivedPass(
            key: key,
            store: store,
            executor: executor,
            configuration: .init(chunkSize: 10),
            maximumAnalysisPlans: 3
        )
        #expect(first.reason == .workQuantumCompleted)
        #expect(first.progress.completed == 3)

        let second = await MLIndexRunner.runDerivedPass(
            key: key,
            store: store,
            executor: executor,
            configuration: .init(chunkSize: 10),
            maximumAnalysisPlans: 3
        )
        #expect(second.reason == .workQuantumCompleted)
        #expect(second.progress.completed == 6)
    }

    private func artifact(
        pipeline: MLPipelineID,
        stage: String,
        revision: String
    ) throws -> MLDerivedArtifactIdentity {
        try MLDerivedArtifactIdentity(
            pipelineID: pipeline,
            stageID: .init(rawValue: stage),
            producer: .native(
                providerIdentifier: "apple.vision",
                kind: stage == "barcode" ? .barcodeDetection : .textRecognition,
                requestRevision: revision
            ),
            preprocessingRevision: "bounded-image-v1",
            output: stage == "barcode" ? .barcodePayload : .recognizedText,
            schemaEpoch: 1
        )
    }

    private func executionKey(
        account: String = "account",
        pipeline: MLPipelineID,
        artifacts: Set<MLDerivedArtifactIdentity>
    ) throws -> MLPipelineExecutionKey {
        try MLPipelineExecutionKey(
            accountIdentifier: account,
            pipelineID: pipeline,
            schemaVersion: 1,
            artifacts: artifacts
        )
    }

    private func uid(_ value: String) -> PhotoUID {
        PhotoUID(volumeID: "volume", nodeID: value)
    }

    private func asset(_ value: String) throws -> MLPipelineAssetRevision {
        try MLPipelineAssetRevision(uid: uid(value), sourceRevision: "source-v1")
    }
}

private actor RecordingExecutor: MLDerivedPipelineExecutor {
    private let handler: @Sendable (MLAssetAnalysisPlan) -> [MLPipelineStageResult]
    private(set) var executionCount = 0

    init(handler: @escaping @Sendable (MLAssetAnalysisPlan) -> [MLPipelineStageResult]) {
        self.handler = handler
    }

    func execute(_ plan: MLAssetAnalysisPlan) async -> [MLPipelineStageResult] {
        executionCount += 1
        return handler(plan)
    }
}

private actor ConcurrencyMeasuringExecutor: MLDerivedPipelineExecutor {
    private var active = 0
    private(set) var maximumObserved = 0
    private(set) var executionCount = 0

    func execute(_ plan: MLAssetAnalysisPlan) async -> [MLPipelineStageResult] {
        executionCount += 1
        active += 1
        maximumObserved = max(maximumObserved, active)
        try? await Task.sleep(for: .milliseconds(30))
        active -= 1
        return plan.workItems.map {
            MLPipelineStageResult(
                workItem: $0,
                outcome: .completed(.init(payload: Data("ok".utf8)))
            )
        }
    }
}
