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
                submit: { [unowned self] identifier, completion in
                    submitted.append(identifier)
                    completion(submitError)
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

    @Test func aFailedRegistrationSubmitsNothing() {
        let scheduler = Scheduler()
        scheduler.registrationSucceeds = false
        let submission = scheduler.makeSubmission()

        submission.submitIfAllowed(owesWork: true)

        #expect(scheduler.submitted.isEmpty)
        #expect(!submission.hasActiveTask)
    }
}
