import PhotosCore
import Testing
import UploadCore
import UploadFeature

@Suite @MainActor
struct BackupProblemListModelTests {
    @Test func sectionsKeepTheirOrderAndTheOriginalRows() {
        let model = BackupProblemListModel()
        let permanent = item("permanent", issue: .unsupported)
        let waiting = item("waiting", issue: .network)
        let decision = item("decision", issue: .deletedElsewhere)
        let action = item("action", issue: .accountStorage)
        model.replaceItems([permanent, waiting, decision, action])

        #expect(model.sections.map(\.id) == [.actionNeeded, .continuesByItself, .notPossible])
        #expect(model.sections.map(\.items) == [[decision, action], [waiting], [permanent]])
        #expect(model.sections.map(\.title) == BackupIssueSection.allCases.map(\.localizedTitle))
        #expect(model.items.offersUserRetry)
    }

    @Test func emptySectionsDisappearAfterDismissal() {
        let model = BackupProblemListModel()
        model.replaceItems([item("permanent", issue: .unsupported)])
        model.dismissItem(id: "permanent")
        #expect(model.items.isEmpty)
        #expect(model.sections.isEmpty)
        #expect(!model.items.offersUserRetry)
    }

    @Test func refreshKeepsAnUnresolvedDecisionAndOtherPhotos() async {
        let model = BackupProblemListModel()
        let decision = item("decision", issue: .deletedElsewhere)
        let waiting = item("waiting", issue: .network)
        await model.refresh(afterDecision: decision) { [decision, waiting] }
        #expect(model.items == [decision, waiting])
    }

    @Test func refreshRemovesTheResolvedDecisionUntilTheNextListUpdate() async {
        let model = BackupProblemListModel()
        let decision = item("decision", issue: .deletedElsewhere)
        let reopened = item("decision", issue: .network)
        let other = item("other", issue: .network)
        await model.refresh(afterDecision: decision) { [reopened, other] }
        #expect(model.items == [other])
        model.replaceItems([reopened, other])
        #expect(model.items == [reopened, other])
    }

    @Test func ordinaryRefreshDoesNotFilterAReopenedPhoto() async {
        let model = BackupProblemListModel()
        let reopened = item("decision", issue: .network)
        await model.refresh { [reopened] }
        #expect(model.items == [reopened])
        #expect(model.sections.map(\.id) == [.continuesByItself])
        #expect(!model.items.offersUserRetry)
    }

    private func item(_ id: String, issue: BackupIssueKind) -> BackupFailedItem {
        BackupFailedItem(
            id: id, filename: "\(id).heic", reason: "Localized reason", isPermanent: false,
            issue: issue, nextAttemptAt: .distantFuture)
    }
}
