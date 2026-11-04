import PhotosCore
import SwiftUI
import UploadCore

/// One fixed area for consent, progress and the acknowledged result. Closing its host never cancels a run.
public struct BulkBackUpAgainControls: View {
    private let runner: BulkPhotoActionRunner
    private let count: Int
    private let availability: @MainActor () -> Bool
    private let prepare: @MainActor () async -> BulkPhotoActionRunner.Confirmation?
    private let start: @MainActor (BulkPhotoActionRunner.Confirmation) -> Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isPreparing = false
    @State private var pending: BulkPhotoActionRunner.Confirmation?
    @State private var showsConfirmation = false

    public init(
        runner: BulkPhotoActionRunner, count: Int, isAvailable: @escaping @MainActor () -> Bool,
        prepare: @escaping @MainActor () async -> BulkPhotoActionRunner.Confirmation?,
        start: @escaping @MainActor (BulkPhotoActionRunner.Confirmation) -> Bool
    ) {
        self.runner = runner
        self.count = count
        availability = isAvailable
        self.prepare = prepare
        self.start = start
    }

    public var body: some View {
        VStack(spacing: 0) {
            if runner.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    Text(progress)
                        .accessibilityIdentifier("backup.bulk.progress")
                    ProgressView(value: Double(runner.processed), total: Double(max(1, runner.total)))
                    Text(
                        outcome(
                            completed: runner.completed, total: runner.total,
                            stayed: runner.processed - runner.completed)
                    )
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.string("backup.bulk_queued_detail")).font(.caption)
                    Button(L10n.string("action.cancel")) { runner.cancel() }
                        .accessibilityIdentifier("backup.bulk.cancel")
                }
                .padding()
                .background(.bar)
            } else if let summary = runner.summary {
                VStack(alignment: .leading, spacing: 8) {
                    if summary.cancelled { Text(L10n.string("backup.bulk_cancelled")) }
                    Text(outcome(completed: summary.completed, total: summary.total, stayed: summary.stayed))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("backup.bulk.result")
                    Text(L10n.string("backup.bulk_queued_detail")).font(.caption)
                    Button(L10n.string("action.ok")) { runner.dismissSummary() }
                        .accessibilityLabel(L10n.string("backup.bulk_dismiss_result"))
                        .accessibilityIdentifier("backup.bulk.dismissResult")
                }
                .padding()
                .background(.bar)
            } else if count > 0, !isPreparing {
                let layout =
                    dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    Text(
                        count == 1
                            ? L10n.string("backup.bulk_count_one \(number(count))")
                            : L10n.string("backup.bulk_count_other \(number(count))")
                    )
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("backup.bulk.count")
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    Button(L10n.string("backup.bulk_action \(number(count))")) { isPreparing = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isAvailable)
                        .accessibilityIdentifier("backup.bulk.backUpAgain")
                }
                .padding()
                .background(.bar)
            }
        }
        .alert(confirmationTitle, isPresented: $showsConfirmation, presenting: pending) { confirmation in
            Button(L10n.string("backup.back_up_again")) {
                _ = start(confirmation)
                pending = nil
            }
            .accessibilityIdentifier("backup.bulk.confirm")
            Button(L10n.string("action.cancel"), role: .cancel) { clearConfirmation() }
        } message: { _ in
            Text(L10n.string("backup.bulk_message"))
        }
        .onChange(of: showsConfirmation) { _, visible in
            if !visible { clearConfirmation() }
        }
        .onChange(of: runner.confirmation?.id) { _, id in
            if id == nil { showsConfirmation = false }
        }
        .onChange(of: isAvailable) { _, available in
            if !available {
                isPreparing = false
                clearConfirmation()
            }
        }
        .onDisappear {
            isPreparing = false
            clearConfirmation()
        }
        .task(id: isPreparing) {
            guard isPreparing, isAvailable else { return }
            let confirmation = await prepare()
            guard !Task.isCancelled else { return }
            isPreparing = false
            guard isAvailable else {
                clearConfirmation()
                return
            }
            if let confirmation {
                pending = confirmation
                showsConfirmation = true
            }
        }
    }

    private var isAvailable: Bool { availability() }

    private var confirmationTitle: String {
        let total = pending?.count ?? 0
        return total == 1
            ? L10n.string("backup.bulk_title_one \(number(total))")
            : L10n.string("backup.bulk_title_other \(number(total))")
    }

    private var progress: String {
        runner.total == 1
            ? L10n.string("backup.bulk_progress_one \(number(runner.processed)) \(number(runner.total))")
            : L10n.string("backup.bulk_progress_other \(number(runner.processed)) \(number(runner.total))")
    }

    private func outcome(completed: Int, total: Int, stayed: Int) -> String {
        total == 1
            ? L10n.string("backup.bulk_outcome_one \(number(completed)) \(number(total)) \(number(stayed))")
            : L10n.string("backup.bulk_outcome_other \(number(completed)) \(number(total)) \(number(stayed))")
    }

    private func number(_ value: Int) -> String { value.formatted(.number) }

    private func clearConfirmation() {
        showsConfirmation = false
        pending = nil
        runner.dismissConfirmation()
    }
}
