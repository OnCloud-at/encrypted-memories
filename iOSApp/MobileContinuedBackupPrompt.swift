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
    /// How often the place looks at what covers it, only while it waits to ask or while the question shows:
    /// presentations post no notification.
    static let coverCheckInterval: Duration = .milliseconds(500)

    let controller: PhotoLibraryBackupController?

    @Environment(\.scenePhase) private var scenePhase
    @State private var asker = PhotoLibraryContinuedBackupPrompt.Asker(marker: .stored())
    @State private var probe = MobileContinuedBackupPromptProbe()
    @State private var isPresented = false
    @State private var estimate: (remaining: Int, bytes: Int64?)?

    private typealias Prompt = PhotoLibraryContinuedBackupPrompt

    /// What can let the place ask, or stop asking: the place looks again when one of them changes.
    private struct Trigger: Equatable {
        let phase: BackupStatus.Phase?
        let remaining: Int
        let owesWork: Bool
        let isSyncing: Bool
        let scenePhase: ScenePhase
        let isPresented: Bool
    }

    private var trigger: Trigger {
        Trigger(
            phase: controller?.status.phase, remaining: controller?.status.remainingCount ?? 0,
            owesWork: controller?.status.hasOutstandingWork ?? false, isSyncing: controller?.isSyncing ?? false,
            scenePhase: scenePhase, isPresented: isPresented)
    }

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
            .task(id: trigger) { await look() }
            .onAppear { if scenePhase == .active { asker.sceneBecameActive(at: .now) } }
            .onChange(of: scenePhase) { _, phase in
                if !Self.sceneChanged(to: phase, asker: asker, at: .now) { isPresented = false }
            }
            .onChange(of: isPresented) { _, shows in
                // The alert went away without a button, for example with its place: no answer.
                if !shows { asker.questionClosed() }
            }
            .onDisappear {
                asker.questionClosed()
                isPresented = false
            }
    }

    /// Looks at the backup when it changes. While the place waits to ask, or while the question shows, it also looks
    /// at what covers the place until that changes.
    private func look() async {
        guard let controller else { return }
        asker.backupChanged(controller.status, isSyncing: controller.isSyncing)
        while !Task.isCancelled {
            if asker.isPresenting {
                asker.coverChanged(isCovered: probe.coversPlace(ownQuestionShows: true), at: .now)
                if !asker.isPresenting {
                    isPresented = false
                    return
                }
                try? await Task.sleep(for: Self.coverCheckInterval)
                continue
            }
            let isTaskActive = PhotoBackupContinuedTask.shared.submission.hasActiveTask
            guard asker.isWaitingToAsk(controller.status, isTaskActive: isTaskActive) else { return }
            // The bytes come first; the cover and the decision follow without a pause in between.
            let bytes = await estimatedBytes(for: controller.status, of: controller)
            guard !Task.isCancelled else { return }
            asker.coverChanged(isCovered: probe.coversPlace(ownQuestionShows: false), at: .now)
            let next = asker.next(controller.status, estimatedBytes: bytes, isTaskActive: isTaskActive, at: .now)
            if next == .ask { isPresented = true }
            guard let pause = Self.pause(after: next) else { return }
            try? await Task.sleep(for: pause)
        }
    }

    /// How long the place sleeps before it looks again; nil when it stops looking because it asks, or because only a
    /// change of the backup or the scene can let it ask. It sleeps through the calm time in steps, so a cover that comes
    /// and goes within it is seen.
    static func pause(after next: PhotoLibraryContinuedBackupPrompt.Asker.Next) -> Duration? {
        switch next {
        case .ask, .none: nil
        case .wait(let calmIn): min(calmIn, coverCheckInterval)
        case .held: coverCheckInterval
        }
    }

    /// Reports the scene phase to the place's rules. Returns false when the question must close: leaving the app
    /// counts as "Not Now". An inactive scene, as under Control Center, asks nothing and closes nothing.
    static func sceneChanged(
        to phase: ScenePhase, asker: PhotoLibraryContinuedBackupPrompt.Asker, at now: ContinuousClock.Instant
    ) -> Bool {
        switch phase {
        case .active: asker.sceneBecameActive(at: now)
        case .inactive: asker.sceneBecameInactive()
        case .background:
            asker.sceneEnteredBackground()
            return false
        @unknown default: asker.sceneBecameInactive()
        }
        return true
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

/// What covers a place of the question, read from UIKit's own state:
/// - the view controller that holds the place (`UIResponder.next`: "Returns the next responder in the responder
///   chain") and the view controllers presented over it (`UIViewController.presentedViewController`: "The view
///   controller that is presented by this view controller, or one of its ancestors in the view controller hierarchy.");
/// - a text field or text view of the place's own window scene that is being edited
///   (`UITextField.textDidBeginEditingNotification`: "A notification that alerts observers when an editing session
///   begins in a text field", and the matching end and text view notifications).
@MainActor
final class MobileContinuedBackupPromptProbe {
    /// A view without content inside the place, so the probe finds the place's view controller.
    struct Anchor: UIViewRepresentable {
        let probe: MobileContinuedBackupPromptProbe

        func makeUIView(context: Context) -> UIView { probe.anchorView() }

        func updateUIView(_ view: UIView, context: Context) {}
    }

    private weak var view: UIView?

    init() {
        TextEditing.startObserving()
    }

    /// The view that marks the place in its view hierarchy.
    func anchorView() -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        self.view = view
        return view
    }

    /// Something covers the place: more presentations than the own question, or text input in its window scene. A
    /// place whose view controller is not found counts as covered, so it never asks blind.
    func coversPlace(ownQuestionShows: Bool) -> Bool {
        guard let presentations = presentationsOverPlace() else { return true }
        return presentations > (ownQuestionShows ? 1 : 0) || isEditingText
    }

    /// How many view controllers are presented over the place, one over the other; nil when the place has no view
    /// controller yet.
    func presentationsOverPlace() -> Int? {
        var responder: UIResponder? = view
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let controller = responder as? UIViewController else { return nil }
        var presented = controller.presentedViewController
        var count = 0
        while let current = presented {
            count += 1
            presented = current.presentedViewController
        }
        return count
    }

    /// A text field or text view in the place's own window scene is being edited.
    var isEditingText: Bool {
        guard let scene = view?.window?.windowScene else { return false }
        return TextEditing.editors.allObjects.contains { $0.isFirstResponder && $0.window?.windowScene === scene }
    }

    /// The text fields and text views that began editing, held weakly, from UIKit's notifications.
    @MainActor
    private enum TextEditing {
        static let editors = NSHashTable<UIView>.weakObjects()
        private static var observers: [NSObjectProtocol] = []

        static func startObserving() {
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            for (began, ended) in [
                (UITextField.textDidBeginEditingNotification, UITextField.textDidEndEditingNotification),
                (UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification),
            ] {
                observers.append(
                    center.addObserver(forName: began, object: nil, queue: .main) { note in
                        guard let editor = note.object as? UIView else { return }
                        MainActor.assumeIsolated { editors.add(editor) }
                    })
                observers.append(
                    center.addObserver(forName: ended, object: nil, queue: .main) { note in
                        guard let editor = note.object as? UIView else { return }
                        MainActor.assumeIsolated { editors.remove(editor) }
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
