import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import Testing

@MainActor @Suite struct PhotoLibraryContinuedBackupSubmissionTests {
    /// The scheduler as the submission sees it: registrations, submissions and their answers.
    @MainActor private final class Scheduler {
        var sceneActive = true
        var registrationSucceeds = true
        var submitError: (any Error)?
        /// The scheduler answers off the main thread, as `submitTaskRequest(_:)` from iOS 27 does.
        var answersOffTheMainThread = false
        private(set) var registered: [String] = []
        private(set) var submitted: [String] = []
        private var counter = 0

        func makeSubmission() -> PhotoLibraryContinuedBackupSubmission {
            PhotoLibraryContinuedBackupSubmission(
                isSceneActive: { [unowned self] in sceneActive },
                makeIdentifier: { [unowned self] in
                    counter += 1
                    return "continued.\(counter)"
                },
                register: { [unowned self] identifier in
                    registered.append(identifier)
                    return registrationSucceeds
                },
                blocking: { [unowned self] identifier in
                    submitted.append(identifier)
                    if let submitError { throw submitError }
                },
                offMainThread: { [unowned self] identifier in
                    guard answersOffTheMainThread else { return nil }
                    submitted.append(identifier)
                    let error = submitError.map { _ in CocoaError(.featureUnsupported) }
                    return {
                        try await Task.sleep(for: .milliseconds(10))
                        if let error { throw error }
                    }
                },
                log: BackgroundWorkLog { _, _ in })
        }
    }

    @Test func continueSubmitsOneTaskFromTheForegroundWhileWorkIsOwed() {
        let scheduler = Scheduler()
        let submission = scheduler.makeSubmission()

        submission.submitIfAllowed(owesWork: true)

        #expect(scheduler.registered == ["continued.1"], "the identifier is registered before its submission")
        #expect(scheduler.submitted == ["continued.1"])
        #expect(submission.hasActiveTask)
        #expect(submission.isCurrent("continued.1"))
    }

    @Test func withoutOwedWorkOrOutsideTheForegroundNothingIsSubmitted() {
        let scheduler = Scheduler()
        let submission = scheduler.makeSubmission()

        submission.submitIfAllowed(owesWork: false)
        scheduler.sceneActive = false
        submission.submitIfAllowed(owesWork: true)

        #expect(scheduler.registered.isEmpty)
        #expect(scheduler.submitted.isEmpty)
        #expect(!submission.hasActiveTask)
    }

    @Test func aSecondAnswerWhileATaskRunsSubmitsNothing() {
        let scheduler = Scheduler()
        let submission = scheduler.makeSubmission()

        submission.submitIfAllowed(owesWork: true)
        submission.submitIfAllowed(owesWork: true)

        #expect(scheduler.submitted == ["continued.1"])
    }

    @Test func theEndOfTheTaskLeavesRoomForTheNextAnswer() {
        let scheduler = Scheduler()
        let submission = scheduler.makeSubmission()
        submission.submitIfAllowed(owesWork: true)

        submission.taskEnded("an-earlier-task")
        #expect(submission.hasActiveTask, "only the current task's end counts")
        submission.taskEnded("continued.1")
        #expect(!submission.hasActiveTask)

        submission.submitIfAllowed(owesWork: true)
        #expect(scheduler.submitted == ["continued.1", "continued.2"])
    }

    @Test func aRefusedSubmissionLeavesRoomForTheNextAnswerWithANewIdentifier() {
        let scheduler = Scheduler()
        let submission = scheduler.makeSubmission()
        scheduler.submitError = CocoaError(.featureUnsupported)

        submission.submitIfAllowed(owesWork: true)
        #expect(!submission.hasActiveTask, "a refused request leaves no active task")

        scheduler.submitError = nil
        submission.submitIfAllowed(owesWork: true)
        // Each identifier is registered once: a second registration of one identifier ends the app.
        #expect(scheduler.registered == ["continued.1", "continued.2"])
        #expect(submission.hasActiveTask)
    }

    /// iOS 27 answers after a delay and off the main thread. The answer must still arrive, so a refusal frees the slot.
    @Test func anAnswerOffTheMainThreadArrivesAndARefusalFreesTheSlot() async {
        let scheduler = Scheduler()
        scheduler.answersOffTheMainThread = true
        scheduler.submitError = CocoaError(.featureUnsupported)
        let submission = scheduler.makeSubmission()

        submission.submitIfAllowed(owesWork: true)
        #expect(submission.hasActiveTask, "the task counts as active until the answer")
        let deadline = ContinuousClock.now + .seconds(2)
        while submission.hasActiveTask, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(scheduler.submitted == ["continued.1"])
        #expect(!submission.hasActiveTask, "the refusal arrived and freed the slot")
    }

    @Test func aFailedRegistrationSubmitsNothing() {
        let scheduler = Scheduler()
        scheduler.registrationSucceeds = false
        let submission = scheduler.makeSubmission()

        submission.submitIfAllowed(owesWork: true)

        #expect(scheduler.submitted.isEmpty)
        #expect(!submission.hasActiveTask)
    }
}
