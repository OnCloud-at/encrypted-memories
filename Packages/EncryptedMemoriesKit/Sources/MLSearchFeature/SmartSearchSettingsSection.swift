import Foundation
import MLSearchCore
import PhotosCore
import SwiftUI

enum SmartSearchVisualSearchEnableAction: Equatable {
    case showInlineModelChoices
    case enableSelectedModel
}

enum SmartSearchVisualSearchPresentationPolicy {
    static func isToggleOn(
        isEnabled: Bool,
        hasSelectedModel: Bool,
        isChoosingInitialModel: Bool
    ) -> Bool {
        isChoosingInitialModel || (isEnabled && hasSelectedModel)
    }

    static func enableAction(hasSelectedModel: Bool) -> SmartSearchVisualSearchEnableAction {
        hasSelectedModel ? .enableSelectedModel : .showInlineModelChoices
    }
}

/// Shared Smart Search settings for macOS, iOS and iPadOS.
public struct SmartSearchSettingsSection: View {
    private let controller: MLSmartSearchController
    @State private var pendingModelSwitch: MLModelCatalogEntry?
    @State private var confirmingDisable = false
    @State private var confirmingVisualSearchDisable = false
    @State private var isChoosingInitialVisualSearchModel = false
    @State private var pickingDeveloperArtifact = false
    @State private var developerInstallTarget: MLModelID?

    public init(controller: MLSmartSearchController) {
        self.controller = controller
    }

    public var body: some View {
        let hasSelectableModel = !controller.snapshot.availableModels.isEmpty
        Section {
            Toggle(isOn: enabledBinding) {
                Text(MLSmartSearchPresentation.productName)
            }
            .accessibilityIdentifier("smartsearch.toggle")

            if controller.snapshot.isEnabled {
                Text(L10n.string("mlsearch.native_search_intro"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                statusRows
                storageRows

                Toggle(isOn: visualSearchBinding) {
                    Text(L10n.string("mlsearch.semantic_section_title"))
                }
                .accessibilityIdentifier("smartsearch.visual.toggle")

                Text(L10n.string("mlsearch.visual_search_intro"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isChoosingInitialVisualSearchModel || controller.snapshot.isVisualSearchEnabled {
                    if hasSelectableModel {
                        modelChoices
                    }
                    modelStatusRows
                }
            }
        } footer: {
            Text(MLSmartSearchPresentation.privacyStatement)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .animation(.easeInOut(duration: 0.2), value: controller.snapshot.isVisualSearchEnabled)
        .animation(.easeInOut(duration: 0.2), value: isChoosingInitialVisualSearchModel)
        .onChange(of: controller.snapshot.selectedModelID) { _, selectedModelID in
            if selectedModelID != nil {
                isChoosingInitialVisualSearchModel = false
            }
        }
        .alert(
            L10n.string("mlsearch.disable_confirm_title \(MLSmartSearchPresentation.productName)"),
            isPresented: $confirmingDisable
        ) {
            Button(L10n.string("action.cancel"), role: .cancel) {}
            Button(L10n.string("mlsearch.disable_confirm_action"), role: .destructive) {
                controller.disableAndPurge()
            }
        } message: {
            Text(L10n.string("mlsearch.disable_confirm_message"))
        }
        .alert(
            L10n.string("mlsearch.visual_disable_confirm_title"),
            isPresented: $confirmingVisualSearchDisable
        ) {
            Button(L10n.string("action.cancel"), role: .cancel) {}
            Button(L10n.string("mlsearch.visual_disable_confirm_action"), role: .destructive) {
                controller.setVisualSearchEnabled(false)
            }
        } message: {
            Text(L10n.string("mlsearch.visual_disable_confirm_message"))
        }
        .alert(
            L10n.string("mlsearch.switch_confirm_title"),
            isPresented: Binding(
                get: { pendingModelSwitch != nil },
                set: { if !$0 { pendingModelSwitch = nil } }
            )
        ) {
            Button(L10n.string("mlsearch.switch_confirm_action")) {
                if let target = pendingModelSwitch {
                    activate(target)
                }
                pendingModelSwitch = nil
            }
            Button(L10n.string("action.cancel"), role: .cancel) { pendingModelSwitch = nil }
        } message: {
            Text(L10n.string("mlsearch.switch_confirm_message"))
        }
        .fileImporter(
            isPresented: $pickingDeveloperArtifact,
            allowedContentTypes: [.folder]
        ) { result in
            // The controller keeps the security scope open until installation completes.
            if case .success(let url) = result, let target = developerInstallTarget {
                controller.installDeveloperModel(from: url, for: target)
            }
            developerInstallTarget = nil
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.snapshot.isEnabled },
            set: { enable in
                if enable {
                    controller.setEnabled(true)
                } else {
                    confirmingDisable = true
                }
            }
        )
    }

    private var visualSearchBinding: Binding<Bool> {
        Binding(
            get: {
                SmartSearchVisualSearchPresentationPolicy.isToggleOn(
                    isEnabled: controller.snapshot.isVisualSearchEnabled,
                    hasSelectedModel: controller.snapshot.selectedModelID != nil,
                    isChoosingInitialModel: isChoosingInitialVisualSearchModel
                )
            },
            set: { enable in
                if enable {
                    switch SmartSearchVisualSearchPresentationPolicy.enableAction(
                        hasSelectedModel: controller.snapshot.selectedModelID != nil
                    ) {
                    case .showInlineModelChoices:
                        isChoosingInitialVisualSearchModel = true
                    case .enableSelectedModel:
                        controller.setVisualSearchEnabled(true)
                    }
                } else if isChoosingInitialVisualSearchModel {
                    isChoosingInitialVisualSearchModel = false
                } else {
                    confirmingVisualSearchDisable = true
                }
            }
        )
    }

    @ViewBuilder
    private var modelChoices: some View {
        let snapshot = controller.snapshot

        Text(L10n.string("mlsearch.model_choice_intro"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        ForEach(snapshot.availableModels) { model in
            Button {
                choose(model)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(
                        systemName: snapshot.selectedModelID == model.id
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .foregroundStyle(snapshot.selectedModelID == model.id ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.string(dynamicKey: model.localizedMetadata.selectionTitleKey))
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            if let size = modelDownloadSize(model) {
                                Text(size)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        Text(L10n.string(dynamicKey: model.localizedMetadata.selectionDescriptionKey))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.modelPresentation.isBusy)
            .accessibilityLabel(Text(L10n.string(dynamicKey: model.localizedMetadata.selectionTitleKey)))
            .accessibilityValue(Text(L10n.string(dynamicKey: model.localizedMetadata.selectionDescriptionKey)))
        }

        if let selected = snapshot.availableModels.first(where: { $0.id == snapshot.selectedModelID }),
            selected.releaseTrack == .developerOnly
        {
            Text(MLSmartSearchPresentation.developerModelNote)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var modelStatusRows: some View {
        let presentation = controller.modelPresentation
        if let status = presentation.statusText {
            VStack(alignment: .leading, spacing: 6) {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let detail = presentation.detailText {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let progress = presentation.progressFraction {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
            }
            if presentation.canRetry {
                Button {
                    controller.retry()
                } label: {
                    Label(L10n.string("action.retry"), systemImage: "arrow.clockwise")
                }
            }
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        let presentation = controller.presentation

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: statusSymbolName)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.statusText)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = presentation.detailText {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ProgressView(value: presentation.progressFraction ?? 0)
                .progressViewStyle(.linear)
                .opacity(presentation.progressFraction == nil ? 0 : 1)
                .accessibilityHidden(presentation.progressFraction == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(presentation.statusText))
        .accessibilityValue(Text(presentation.detailText ?? ""))

        if presentation.canRetry {
            Button {
                controller.retry()
            } label: {
                Label(L10n.string("action.retry"), systemImage: "arrow.clockwise")
            }
        }
    }

    @ViewBuilder
    private var storageRows: some View {
        let storage = controller.storageBreakdown
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string("mlsearch.storage_title \(MLSmartSearchPresentation.productName)"))
                    .font(.headline)
                Spacer()
                Button {
                    controller.refreshStorageBreakdown()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(L10n.string("mlsearch.storage_refresh")))
            }
            storageRow("mlsearch.storage_vision", bytes: storage.appleVisionIndexBytes)
            storageRow("mlsearch.storage_vectors", bytes: storage.semanticVectorIndexBytes)
            storageRow("mlsearch.storage_models", bytes: storage.installedVisualModelsBytes)
            storageRow("mlsearch.storage_partial", bytes: storage.partialModelDownloadsBytes)
            storageRow("mlsearch.storage_other", bytes: storage.otherMLDataBytes)
            Divider()
            storageRow("mlsearch.storage_total", bytes: storage.totalBytes)
        }
        .accessibilityElement(children: .contain)
    }

    private func storageRow(_ key: String, bytes: Int64) -> some View {
        LabeledContent(L10n.string(dynamicKey: key)) {
            Text(L10n.fileSize(bytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var statusSymbolName: String {
        if controller.presentation.presentsAsReady { return "checkmark.circle.fill" }
        switch controller.snapshot.indexingState {
        case .indexing: return "sparkles"
        case .waiting: return "pause.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle, .ready: break
        }
        return switch controller.snapshot.phase {
        case .disabled: "minus.circle"
        case .loadingCatalog: "arrow.triangle.2.circlepath"
        case .selectingModel: "cpu"
        case .notInstalled: "arrow.down.circle"
        case .downloading: "arrow.down.circle.fill"
        case .verifying: "checkmark.shield"
        case .installing: "square.and.arrow.down"
        case .preparingModel: "cpu"
        case .indexing: "sparkles"
        case .waiting: "pause.circle"
        case .ready: "checkmark.circle.fill"
        case .switchingModel: "arrow.triangle.2.circlepath"
        case .deleting: "trash"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        if controller.presentation.presentsAsReady { return .green }
        if case .failed = controller.snapshot.indexingState { return .orange }
        return switch controller.snapshot.phase {
        case .failed: .orange
        case .ready: .green
        default: .secondary
        }
    }

    private func choose(_ model: MLModelCatalogEntry) {
        let snapshot = controller.snapshot
        guard model.id != snapshot.selectedModelID else { return }
        if snapshot.selectedModelID == nil {
            activate(model)
        } else {
            pendingModelSwitch = model
        }
    }

    private func activate(_ model: MLModelCatalogEntry) {
        if model.releaseTrack == .developerOnly, !model.isDownloadable {
            developerInstallTarget = model.id
            pickingDeveloperArtifact = true
        } else {
            controller.select(model.id)
        }
    }

    private func modelDownloadSize(_ model: MLModelCatalogEntry) -> String? {
        guard let bytes = model.downloadPlan?.totalByteCount, bytes > 0 else { return nil }
        let size = L10n.fileSize(bytes)
        return size
    }
}
