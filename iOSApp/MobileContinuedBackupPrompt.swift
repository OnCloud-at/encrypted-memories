import PhotoLibraryBackupAdapter
import PhotosCore
import SwiftUI
import UIKit
import UploadCore

/// The question whether the backup may continue in the background (#1108). One modifier, attached at the root of the
/// scene and on the backup screen in its sheet. The shared `PhotoLibraryContinuedBackupPrompt.Asker` decides when the
/// place asks; this view shows the alert and reports the scene, the cover and the answer. "Continue" is the person's
/// action that submits the continued processing task.
///
/// HIG Alerts: an alert interrupts, so it comes once per backlog, at a calm point and never over other content; the
/// preferred action is the default button, and "Not Now" has the cancel role.
struct MobileContinuedBackupPromptModifier: ViewModifier {
    /// How often the place looks at the backup and at what covers it. Presentations post no notification.
    static let checkInterval: Duration = .milliseconds(500)

    let controller: PhotoLibraryBackupController?

    @Environment(\.scenePhase) private var scenePhase
    @State private var asker = PhotoLibraryContinuedBackupPrompt.Asker(marker: .stored())
    @State private var probe = MobileContinuedBackupPromptProbe()
    @State private var isPresented = false
    @State private var estimate: (remaining: Int, bytes: Int64?)?

    private typealias Prompt = PhotoLibraryContinuedBackupPrompt

    func body(content: Content) -> some View {
        content
            .background(MobileContinuedBackupPromptProbe.Anchor(probe: probe))
            .alert(L10n.string("backup.continued_prompt_title"), isPresented: $isPresented) {
                Button(L10n.string("backup.continued_prompt_continue")) { answer(accepted: true) }
                    .keyboardShortcut(.defaultAction)
                Button(L10n.string("backup.continued_prompt_not_now"), role: .cancel) { answer(accepted: false) }
            } message: {
                Text(L10n.string("backup.continued_prompt_message"))
            }
            .task {
                while !Task.isCancelled {
                    await check()
                    try? await Task.sleep(for: Self.checkInterval)
                }
            }
            .onAppear { if scenePhase == .active { asker.sceneBecameActive(at: .now) } }
            .onChange(of: scenePhase) { _, phase in
                // Only the background leaves the scene. Control Center or a system alert make it inactive and close
                // nothing.
                switch phase {
                case .active: asker.sceneBecameActive(at: .now)
                case .background:
                    asker.sceneEnteredBackground()
                    isPresented = false
                default: break
                }
            }
            .onDisappear {
                // The place is gone; the question goes with it, without an answer.
                asker.coverChanged(isCovered: true, at: .now)
                isPresented = false
            }
    }

    private func check() async {
        guard let controller else { return }
        let status = controller.status
        asker.backupChanged(status, isSyncing: controller.isSyncing)
        // The own question is one presentation over the place; anything more, or text input, covers it.
        let covered =
            probe.presentationsOverPlace() > (asker.isPresenting ? 1 : 0)
            || MobileContinuedBackupPromptProbe.isEditingText
        asker.coverChanged(isCovered: covered, at: .now)
        if isPresented, !asker.isPresenting { isPresented = false }
        guard !asker.isPresenting else { return }
        let next = asker.next(
            status, estimatedBytes: await estimatedBytes(for: status, of: controller),
            isTaskActive: PhotoBackupContinuedTask.shared.submission.hasActiveTask, at: .now)
        if next == .ask { isPresented = true }
    }

    /// The volume only for a short list, read once for each count of photos left.
    private func estimatedBytes(for status: BackupStatus, of controller: PhotoLibraryBackupController) async -> Int64? {
        guard Prompt.needsVolume(status) else { return nil }
        if let estimate, estimate.remaining == status.remainingCount { return estimate.bytes }
        let bytes = await controller.estimatedOutstandingBytes(limit: Prompt.itemsThatAlwaysAsk - 1)
        estimate = (status.remainingCount, bytes)
        return bytes
    }

    private func answer(accepted: Bool) {
        if asker.answered(accepted: accepted), let controller {
            PhotoBackupContinuedTask.shared.personAccepted(controller: controller)
        }
    }
}

/// What covers a place of the question, read from UIKit's own state: the view controller that holds the place and the
/// view controllers presented over it (`UIViewController.presentedViewController`: "The view controller that is
/// presented by this view controller, or one of its ancestors in the view controller hierarchy."), and text input
/// (`UITextField.textDidBeginEditingNotification` and the matching end and text view notifications).
@MainActor
final class MobileContinuedBackupPromptProbe {
    /// A view without content inside the place, so the probe finds the place's view controller.
    struct Anchor: UIViewRepresentable {
        let probe: MobileContinuedBackupPromptProbe

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            probe.view = view
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {}
    }

    private weak var view: UIView?

    /// How many view controllers are presented over the place, one over the other; 0 when nothing covers it.
    func presentationsOverPlace() -> Int {
        // `UIResponder.next` leads from the view to the view controller that holds it.
        var responder: UIResponder? = view
        while let current = responder, !(current is UIViewController) { responder = current.next }
        var presented = (responder as? UIViewController)?.presentedViewController
        var count = 0
        while let current = presented {
            count += 1
            presented = current.presentedViewController
        }
        return count
    }

    /// A text field or text view in this app is being edited.
    static var isEditingText: Bool { !TextEditing.shared.editors.isEmpty }

    /// The text fields and text views that are being edited, from UIKit's notifications.
    @MainActor
    private final class TextEditing {
        static let shared = TextEditing()
        private(set) var editors = Set<ObjectIdentifier>()
        private var observers: [NSObjectProtocol] = []

        private init() {
            let center = NotificationCenter.default
            for (began, ended) in [
                (UITextField.textDidBeginEditingNotification, UITextField.textDidEndEditingNotification),
                (UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification),
            ] {
                observers.append(
                    center.addObserver(forName: began, object: nil, queue: .main) { note in
                        guard let object = note.object as AnyObject? else { return }
                        let id = ObjectIdentifier(object)
                        MainActor.assumeIsolated { TextEditing.shared.editors.insert(id) }
                    })
                observers.append(
                    center.addObserver(forName: ended, object: nil, queue: .main) { note in
                        guard let object = note.object as AnyObject? else { return }
                        let id = ObjectIdentifier(object)
                        MainActor.assumeIsolated { _ = TextEditing.shared.editors.remove(id) }
                    })
            }
        }
    }
}

extension View {
    /// Asks once per backlog whether the backup may continue in the background (#1108). iPhone and iPad only.
    func continuedBackupPrompt(controller: PhotoLibraryBackupController?) -> some View {
        modifier(MobileContinuedBackupPromptModifier(controller: controller))
    }
}
