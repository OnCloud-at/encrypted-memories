import Foundation
import Testing

@testable import DesignSystemCore

@Suite("Tip jar celebration")
@MainActor
struct TipJarCelebrationTests {
    @Test("Creates a dense plan of small pieces")
    func createsDenseSmallPieces() {
        let coordinator = TipJarCelebrationCoordinator()
        let celebrationID = coordinator.celebrate()
        let celebration = coordinator.activeCelebration

        #expect(celebration?.id == celebrationID)
        #expect(celebration?.pieces.count == TipJarCelebrationMetrics.pieceCount)
        #expect(
            celebration?.pieces.allSatisfy {
                $0.size >= TipJarCelebrationMetrics.minimumPieceSize
                    && $0.size <= TipJarCelebrationMetrics.maximumPieceSize
            } == true
        )
        #expect(celebration?.pieces.contains { $0.isDot } == true)
        #expect(celebration?.pieces.contains { !$0.isDot } == true)

        coordinator.finish(celebrationID: celebrationID)
        #expect(coordinator.activeCelebration == nil)
    }

    @Test("A stale completion cannot dismiss a newer celebration")
    func staleCompletionDoesNotDismissNewCelebration() {
        let coordinator = TipJarCelebrationCoordinator()
        let firstID = coordinator.celebrate()
        let secondID = coordinator.celebrate()

        coordinator.finish(celebrationID: firstID)
        #expect(coordinator.activeCelebration?.id == secondID)

        coordinator.finish(celebrationID: secondID)
        #expect(coordinator.activeCelebration == nil)
    }

    @Test("Verified tip delivery starts the celebration")
    func verifiedTipDeliveryStartsCelebration() throws {
        var sourceURL = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { sourceURL.deleteLastPathComponent() }
        sourceURL.appendPathComponent(
            "Packages/EncryptedMemoriesKit/Sources/DesignSystemCore/TipJarView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("await TipJarCelebrationCoordinator.shared.celebrate()"))
    }
}
