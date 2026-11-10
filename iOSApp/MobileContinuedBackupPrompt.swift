import PhotoLibraryBackupAdapter
import PhotosCore
import SwiftUI
import UploadCore

/// The question whether the backup may continue in the background (#1108). One modifier, attached at the root of the
/// scene and on the backup screen in its sheet: the place that is visible on top asks, and the shared claim lets only one
/// place in the app ask at a time. The shared policy decides when to ask; "Continue" is the person's action that submits
/// the continued processing task.
///
/// HIG Alerts: an alert interrupts, so it comes once per backlog, never at launch, and only at a calm point; the
/// preferred action is the default button, and "Not Now" has the cancel role.
struct MobileContinuedBackupPromptModifier: ViewModifier {
    /// How long a scene is active before it may ask: never right at launch or right after a return to the app.
    static let calmDelay: Duration = .seconds(2)

    /// Where the question is attached.
    enum Place: Equatable {
        /// The root of a scene. `isCovered`: a sheet or cover of the root is shown, or the person searches.
        case root(isCovered: Bool)
        /// The backup screen, which is shown in a sheet; while it is visible, the root of its scene does not ask.
        case backupScreen
    }

    let controller: PhotoLibraryBackupController?
    let attachment: Place
    @State private var places = MobileContinuedBackupPromptPlaces.shared

    private var isCovered: Bool {
        switch attachment {
        case .root(let covered): covered || places.visibleBackupScreens > 0
        case .backupScreen: false
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var place = UUID()
    @State private var isPresented = false
    @State private var activeSince: ContinuousClock.Instant?

    private typealias Prompt = PhotoLibraryContinuedBackupPrompt

    /// What can change the answer of the policy.
    private struct Trigger: Equatable {
        let phase: BackupStatus.Phase?
        let remaining: Int
        let owesWork: Bool
        let isSyncing: Bool
        let isCovered: Bool
        let isActive: Bool
    }

    private var trigger: Trigger {
        Trigger(
            phase: controller?.status.phase, remaining: controller?.status.remainingCount ?? 0,
            owesWork: controller?.status.hasOutstandingWork ?? false, isSyncing: controller?.isSyncing ?? false,
            isCovered: isCovered, isActive: scenePhase == .active)
    }

    func body(content: Content) -> some View {
        content
            .alert(L10n.string("backup.continued_prompt_title"), isPresented: $isPresented) {
                Button(L10n.string("backup.continued_prompt_continue")) { answer(accepted: true) }
                    .keyboardShortcut(.defaultAction)
                Button(L10n.string("backup.continued_prompt_not_now"), role: .cancel) { answer(accepted: false) }
            } message: {
                Text(L10n.string("backup.continued_prompt_message"))
            }
            .task(id: trigger) { await evaluate() }
            .onAppear {
                if attachment == .backupScreen { places.visibleBackupScreens += 1 }
                if scenePhase == .active { activeSince = .now }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { activeSince = .now } else { leave() }
            }
            .onChange(of: isCovered) { _, covered in if covered { leave() } }
            .onDisappear {
                if attachment == .backupScreen { places.visibleBackupScreens -= 1 }
                leave()
            }
    }

    private func evaluate() async {
        guard let controller else { return }
        let defaults = UserDefaults.standard
        if Prompt.backlogDrained(controller.status, isSyncing: controller.isSyncing) {
            defaults.removeObject(forKey: Prompt.askedMarkerKey)
        }
        guard !isPresented, scenePhase == .active, !isCovered, let activeSince else { return }
        let calmIn = Self.calmDelay - (ContinuousClock.now - activeSince)
        if calmIn > .zero {
            try? await Task.sleep(for: calmIn)
            guard !Task.isCancelled else { return }
        }
        let bytes =
            Prompt.needsVolume(controller.status)
            ? await controller.estimatedOutstandingBytes(limit: Prompt.itemsThatAlwaysAsk - 1) : nil
        guard !Task.isCancelled, !isCovered, scenePhase == .active else { return }
        let situation = Prompt.Situation(
            isCalm: true, isTaskActive: PhotoBackupContinuedTask.shared.submission.hasActiveTask,
            wasAsked: defaults.bool(forKey: Prompt.askedMarkerKey))
        guard Prompt.shouldAsk(controller.status, estimatedBytes: bytes, in: situation),
            Prompt.Claim.shared.claim(place)
        else { return }
        isPresented = true
    }

    /// Either answer closes the question for this backlog; only "Continue" starts the task.
    private func answer(accepted: Bool) {
        UserDefaults.standard.set(true, forKey: Prompt.askedMarkerKey)
        Prompt.Claim.shared.release(place)
        if accepted, let controller { PhotoBackupContinuedTask.shared.personAccepted(controller: controller) }
    }

    /// The scene leaves the foreground, or this place is covered, while the question is shown: that counts as
    /// "Not Now", so the question does not come back for the same backlog.
    private func leave() {
        if isPresented {
            UserDefaults.standard.set(true, forKey: Prompt.askedMarkerKey)
            isPresented = false
        }
        Prompt.Claim.shared.release(place)
    }
}

/// The backup screens that are visible in this app. A root must not ask under the sheet that shows one.
@MainActor @Observable
final class MobileContinuedBackupPromptPlaces {
    static let shared = MobileContinuedBackupPromptPlaces()
    var visibleBackupScreens = 0
}

extension View {
    /// Asks once per backlog whether the backup may continue in the background (#1108). iPhone and iPad only.
    func continuedBackupPrompt(
        controller: PhotoLibraryBackupController?, at place: MobileContinuedBackupPromptModifier.Place
    ) -> some View {
        modifier(MobileContinuedBackupPromptModifier(controller: controller, attachment: place))
    }
}
