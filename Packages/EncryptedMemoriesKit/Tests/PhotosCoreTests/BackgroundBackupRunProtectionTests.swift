import Foundation
import Testing

@testable import PhotosCore

@MainActor @Suite struct BackgroundBackupRunProtectionTests {
    private final class Owner {}

    @Test func onlyTheSameControllerAndRunAreProtected() {
        let protection = BackgroundBackupRunProtection()
        let owner = Owner()
        let other = Owner()
        let token = protection.hold(owner: owner, runID: "run")
        #expect(protection.isProtected(owner: owner, runID: "run"))
        #expect(!protection.isProtected(owner: other, runID: "run"))
        #expect(!protection.isProtected(owner: owner, runID: "later"))
        protection.release(token)
        #expect(!protection.isProtected(owner: owner, runID: "run"))
    }

    @Test func eachWindowReleasesOnlyItsOwnProtection() {
        let protection = BackgroundBackupRunProtection()
        let owner = Owner()
        let old = protection.hold(owner: owner, runID: "run")
        let current = protection.hold(owner: owner, runID: "run")
        protection.release(old)
        #expect(protection.isProtected(owner: owner, runID: "run"))
        protection.release(old)
        #expect(protection.isProtected(owner: owner, runID: "run"))
        protection.release(current)
        #expect(!protection.isProtected(owner: owner, runID: "run"))
    }

    @Test func aWindowDoesNotKeepItsControllerAlive() {
        let protection = BackgroundBackupRunProtection()
        var owner: Owner? = Owner()
        weak var released = owner
        let token = protection.hold(owner: owner!, runID: "run")
        owner = nil
        #expect(released == nil)
        protection.release(token)
    }

    @Test func aHoldProtectsOneRunAndTheNextRunReplacesIt() {
        let protection = BackgroundBackupRunProtection()
        let owner = Owner()
        var holds = 0
        let hold = BackgroundBackupRunHold(protection: protection) { holds += 1 }

        hold.hold(owner: owner, runID: "first")
        hold.hold(owner: owner, runID: "first")
        #expect(protection.isProtected(owner: owner, runID: "first"))
        #expect(holds == 1, "holding the same run again changes nothing")

        hold.hold(owner: owner, runID: "second")
        #expect(!protection.isProtected(owner: owner, runID: "first"))
        #expect(protection.isProtected(owner: owner, runID: "second"))
        #expect(hold.heldRunID == "second")
        #expect(holds == 2)

        hold.release()
        hold.release()
        #expect(!protection.isProtected(owner: owner, runID: "second"))
        #expect(hold.heldRunID == nil)
    }

    @Test func aHoldReleasesOnlyItsOwnProtection() {
        let protection = BackgroundBackupRunProtection()
        let owner = Owner()
        let window = BackgroundBackupRunHold(protection: protection)
        let task = BackgroundBackupRunHold(protection: protection)
        window.hold(owner: owner, runID: "run")
        task.hold(owner: owner, runID: "run")

        window.release()

        #expect(protection.isProtected(owner: owner, runID: "run"), "the other holder still protects the run")
        task.release()
        #expect(!protection.isProtected(owner: owner, runID: "run"))
    }
}
