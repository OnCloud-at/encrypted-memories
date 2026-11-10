import XCTest

/// The question whether the backup may continue in the background (#1108). The Simulator cannot run the continued
/// processing task itself, so these tests check the question and its two answers.
final class MobileContinuedBackupPromptUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
    }

    override func tearDown() { app.terminate() }

    private func launch(language: String, locale: String) {
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture", "-EncryptedMemoriesContinuedBackupPromptFixture",
            "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
        ]
        app.launch()
    }

    func testTheQuestionComesOnceAndNotNowKeepsItClosed() {
        launch(language: "en", locale: "en_US")
        let question = app.alerts["Keep backing up in the background?"]
        XCTAssertTrue(question.waitForExistence(timeout: 60), "a large backup does not ask")
        XCTAssertTrue(
            question.staticTexts[
                "Many photos are still waiting. The backup can continue while you use other apps."
            ].exists)

        question.buttons["Not Now"].tap()

        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: question)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        XCTAssertFalse(question.waitForExistence(timeout: 6), "the question comes back for the same photos")
    }

    func testContinueClosesTheQuestionWithoutAnError() {
        launch(language: "en", locale: "en_US")
        let question = app.alerts["Keep backing up in the background?"]
        XCTAssertTrue(question.waitForExistence(timeout: 60))

        question.buttons["Continue"].tap()

        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: question)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 5), "no other alert follows the answer")
    }

    func testTheQuestionSpeaksGerman() {
        launch(language: "de", locale: "de_AT")
        let question = app.alerts["Backup im Hintergrund fortsetzen?"]
        XCTAssertTrue(question.waitForExistence(timeout: 60))
        XCTAssertTrue(question.buttons["Fortsetzen"].exists)
        XCTAssertTrue(question.buttons["Nicht jetzt"].exists)
        question.buttons["Nicht jetzt"].tap()
    }
}
