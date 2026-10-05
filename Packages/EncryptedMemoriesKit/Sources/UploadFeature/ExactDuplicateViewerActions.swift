import PhotosCore
import SwiftUI
import UploadCore

/// The merge tools below the photo of a group of duplicates in the Mac viewer: Keep This Copy for the photo shown, and
/// Merge, which merges the group with the photo shown as kept. The iOS viewer puts the same actions into its native
/// bottom bar.
public struct ExactDuplicateViewerActions: View {
    private let model: ExactDuplicatesModel
    private let groupID: String
    private let current: PhotoUID
    private let onMerge: () -> Void

    /// `onMerge` closes the viewer; the merge itself runs in `model`.
    public init(model: ExactDuplicatesModel, groupID: String, current: PhotoUID, onMerge: @escaping () -> Void) {
        self.model = model
        self.groupID = groupID
        self.current = current
        self.onMerge = onMerge
    }

    public var body: some View {
        let isKept = model.group(withID: groupID)?.kept == current
        HStack {
            Button {
                model.keep(current, inGroup: groupID)
            } label: {
                Label(
                    model.keepTitle(for: current, inGroup: groupID),
                    systemImage: isKept ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .disabled(isKept || model.isMerging)
            .accessibilityIdentifier("duplicates.viewer.keep")
            Spacer(minLength: 12)
            Button(L10n.string("duplicates.merge")) {
                onMerge()
                Task { await model.merge(groupID: groupID) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canMerge || model.group(withID: groupID) == nil)
            .accessibilityIdentifier("duplicates.viewer.merge")
        }
        .controlSize(.large)
    }
}
