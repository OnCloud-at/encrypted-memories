import XCTest

/// "Revert to Original" in the viewer's More menu, on the offline fixture account: every fixture photo is an edit with
/// an original, and the fixture backend reverts at once or, with `-EncryptedMemoriesRevertFixtureFails`, refuses.
final class MobileRevertToOriginalUITests: XCTestCase {
    private var app: XCUIApplication!
    /// The accessibility label of the photo that the test opened in the viewer, so a test can follow that photo.
    private var openedPhotoLabel = ""

    /// The texts that the owner froze, as a person reads them in each language.
    private struct Copy {
        let language: String
        let showOriginal: String
        let command: String
        let title: String
        let message: String
        let confirm: String
        let cancel: String
        let failure: String
        let ok: String
        let close: String

        static let english = Copy(
            language: "en", showOriginal: "Show Original", command: "Revert to Original\u{2026}",
            title: "Revert to Original",
            message: "The original becomes a new photo. The edited version moves to the Trash.",
            confirm: "Revert", cancel: "Cancel", failure: "The original couldn\u{2019}t be restored.", ok: "OK",
            close: "Close")
        static let german = Copy(
            language: "de", showOriginal: "Original zeigen",
            command: "Zum Original zur\u{FC}ckkehren \u{2026}", title: "Zum Original zur\u{FC}ckkehren",
            message: "Das Original wird ein neues Foto. Die bearbeitete Version wandert in den Papierkorb.",
            confirm: "Zur\u{FC}ckkehren", cancel: "Abbrechen",
            failure: "Das Original konnte nicht wiederhergestellt werden.", ok: "OK", close: "Schlie\u{DF}en")
    }

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
    }

    override func tearDown() { app.terminate() }

    /// `gateFile` holds every revert until the test creates that file; the revert then fails.
    private func launch(_ copy: Copy, refusing: Bool = false, gateFile: URL? = nil) {
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture",
            "-AppleLanguages", "(\(copy.language))",
            "-AppleLocale", copy.language == "de" ? "de_DE" : "en_US",
        ]
        if refusing { app.launchArguments.append("-EncryptedMemoriesRevertFixtureFails") }
        if let gateFile { app.launchArguments += ["-EncryptedMemoriesRevertFixtureFailsAfterFile", gateFile.path] }
        app.launch()
    }

    /// Opens the first visible photo and its More menu. The viewer asks for the original after the photo stayed on
    /// screen, so the menu items appear after a wait of unknown length.
    @discardableResult
    private func openViewerMenu(_ copy: Copy) throws -> (more: XCUIElement, command: XCUIElement) {
        let column = copy.language == "en" ? try app.verticalTabColumn() : nil
        let photo = try app.visiblePhoto(beside: column)
        openedPhotoLabel = photo.label
        photo.tap()
        let more = app.viewerMoreButton
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the viewer shows no More menu")
        more.tap()
        let showOriginal = app.buttons[copy.showOriginal]
        let command = app.buttons[copy.command]
        XCTAssertTrue(showOriginal.waitForExistence(timeout: 30), "the More menu offers no \(copy.showOriginal)")
        XCTAssertTrue(command.waitForExistence(timeout: 10), "the More menu offers no \(copy.command)")
        XCTAssertGreaterThan(command.frame.minY, showOriginal.frame.minY, "the command sits below Show Original")
        return (more, command)
    }

    /// The distinct buttons of an alert, counted by label and frame: the accessibility tree can list one drawn button
    /// twice.
    private func distinctButtons(of alert: XCUIElement) -> [String] {
        var seen = Set<String>()
        return alert.buttons.allElementsBoundByIndex.compactMap { button in
            let key = "\(button.label)|\(button.frame)"
            return seen.insert(key).inserted ? button.label : nil
        }
    }

    private func isGone(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        element.waitUntilGone(timeout: timeout) == .completed
    }

    private func presentConfirmation(_ copy: Copy) throws -> (more: XCUIElement, alert: XCUIElement) {
        let (more, command) = try openViewerMenu(copy)
        command.tap()
        let alert = app.alerts[copy.title]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the confirmation did not appear")
        XCTAssertTrue(alert.staticTexts[copy.message].exists, "the confirmation shows the frozen message")
        XCTAssertEqual(
            Set(distinctButtons(of: alert)), [copy.confirm, copy.cancel], "the confirmation has these two buttons")
        return (more, alert)
    }

    // MARK: - English

    func testCancelLeavesThePhotoAndTheViewerAsTheyWere() throws {
        launch(.english)
        let (more, alert) = try presentConfirmation(.english)

        try app.tapDialogButton(Copy.english.cancel)

        XCTAssertTrue(isGone(alert, timeout: 10), "Cancel closes the confirmation")
        XCTAssertTrue(more.exists, "the viewer is still open")
        more.tap()
        XCTAssertTrue(
            app.buttons[Copy.english.command].waitForExistence(timeout: 10),
            "the command is available again after Cancel")
    }

    func testRevertClosesTheViewerAndRemovesTheEditedPhoto() throws {
        launch(.english)
        let (more, alert) = try presentConfirmation(.english)
        let editedPhotoLabel = openedPhotoLabel
        XCTAssertFalse(editedPhotoLabel.isEmpty, "the test did not record the opened photo")

        try app.tapDialogButton(Copy.english.confirm)

        XCTAssertTrue(isGone(alert, timeout: 10), "the confirmation closes")
        XCTAssertTrue(isGone(more), "the viewer closes after the revert")
        XCTAssertFalse(app.alerts.firstMatch.exists, "a successful revert shows no failure")
        let editedPhoto = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", editedPhotoLabel)
        ).firstMatch
        XCTAssertTrue(isGone(editedPhoto), "the edited photo left the grid: \(editedPhotoLabel)")
    }

    func testAFailureShowsTheFrozenTextOnceWithoutRetry() throws {
        launch(.english, refusing: true)
        let (more, _) = try presentConfirmation(.english)

        try app.tapDialogButton(Copy.english.confirm)

        let failure = app.alerts[Copy.english.failure]
        XCTAssertTrue(failure.waitForExistence(timeout: 30), "the failure alert did not appear")
        XCTAssertEqual(distinctButtons(of: failure), [Copy.english.ok], "the failure offers OK and no retry")
        let claim = failure.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'nothing was changed'"))
        XCTAssertEqual(claim.count, 0, "the failure does not claim that nothing was changed")

        try app.tapDialogButton(Copy.english.ok)

        XCTAssertTrue(isGone(failure, timeout: 10), "OK closes the failure")
        XCTAssertTrue(more.exists, "the viewer stays open")
        // The failure shows once: it does not come back.
        XCTAssertFalse(app.alerts[Copy.english.failure].waitForExistence(timeout: 3), "the failure came back")
    }

    // MARK: - German

    func testGermanConfirmationShowsTheFrozenTextAndCancelChangesNothing() throws {
        launch(.german)
        let (more, alert) = try presentConfirmation(.german)

        try app.tapDialogButton(Copy.german.cancel)

        XCTAssertTrue(isGone(alert, timeout: 10), "Abbrechen schlie\u{DF}t die R\u{FC}ckfrage")
        XCTAssertTrue(more.exists, "die Ansicht bleibt offen")
    }

    func testGermanFailureShowsTheFrozenTextOnceWithoutRetry() throws {
        launch(.german, refusing: true)
        let (more, _) = try presentConfirmation(.german)

        try app.tapDialogButton(Copy.german.confirm)

        let failure = app.alerts[Copy.german.failure]
        XCTAssertTrue(failure.waitForExistence(timeout: 30), "die Fehlermeldung erscheint nicht")
        XCTAssertEqual(distinctButtons(of: failure), [Copy.german.ok], "nur OK, kein Wiederholen")

        try app.tapDialogButton(Copy.german.ok)

        XCTAssertTrue(isGone(failure, timeout: 10))
        XCTAssertTrue(more.exists, "die Ansicht bleibt offen")
        XCTAssertFalse(
            app.alerts[Copy.german.failure].waitForExistence(timeout: 3), "die Meldung kommt nicht zur\u{FC}ck")
    }

    // MARK: - A failure after the viewer closed

    func testAFailureAfterTheViewerClosedShowsTheFrozenTextOnceInTheLibrary() throws {
        try assertTheFailureShowsInTheLibraryAfterTheViewerClosed(.english)
    }

    func testGermanFailureAfterTheViewerClosedShowsTheFrozenTextOnceInTheLibrary() throws {
        try assertTheFailureShowsInTheLibraryAfterTheViewerClosed(.german)
    }

    func testAFailureWaitsUntilTheNextViewerCloses() throws {
        let copy = Copy.english
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("revert-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: gate) }
        launch(copy, gateFile: gate)
        let (more, _) = try presentConfirmation(copy)
        try app.tapDialogButton(copy.confirm)
        let close = app.buttons[copy.close].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(isGone(more), "the first viewer closed")

        let column = try app.verticalTabColumn()
        let photo = try app.visiblePhoto(beside: column)
        photo.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the second viewer opened")
        XCTAssertTrue(FileManager.default.createFile(atPath: gate.path, contents: Data()))
        let failure = app.alerts[copy.failure]
        XCTAssertFalse(failure.waitForExistence(timeout: 5), "the failure must not cover the second viewer")
        XCTAssertTrue(more.exists, "the second viewer stays open")
        let secondClose = app.buttons[copy.close].firstMatch
        XCTAssertTrue(secondClose.waitForExistence(timeout: 10))
        secondClose.tap()
        XCTAssertTrue(isGone(more), "the second viewer closed")
        XCTAssertTrue(failure.waitForExistence(timeout: 30), "the failure appears after the second viewer closes")
        XCTAssertEqual(distinctButtons(of: failure), [copy.ok])
        try app.tapDialogButton(copy.ok)
        XCTAssertTrue(isGone(failure, timeout: 10))
        XCTAssertFalse(failure.waitForExistence(timeout: 3), "the failure came back")
    }

    /// The fixture holds the revert until the test creates the gate file, so the viewer is closed before the failure
    /// arrives. The library then shows the same alert once, with OK only.
    private func assertTheFailureShowsInTheLibraryAfterTheViewerClosed(_ copy: Copy) throws {
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("revert-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: gate) }
        launch(copy, gateFile: gate)
        let (more, _) = try presentConfirmation(copy)
        try app.tapDialogButton(copy.confirm)

        let close = app.buttons[copy.close].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer shows no \(copy.close) while the revert runs")
        XCTAssertFalse(app.alerts[copy.failure].exists, "the revert is still held, so nothing failed yet")
        close.tap()
        XCTAssertTrue(isGone(more), "the viewer closed")

        XCTAssertTrue(
            FileManager.default.createFile(atPath: gate.path, contents: Data()), "the test could not open the gate")

        let failure = app.alerts[copy.failure]
        XCTAssertTrue(failure.waitForExistence(timeout: 30), "the failure did not appear in the library")
        XCTAssertEqual(distinctButtons(of: failure), [copy.ok], "the failure offers OK and no retry")

        try app.tapDialogButton(copy.ok)

        XCTAssertTrue(isGone(failure, timeout: 10), "OK closes the failure")
        // The failure shows once: it does not come back.
        XCTAssertFalse(app.alerts[copy.failure].waitForExistence(timeout: 3), "the failure came back")
    }
}
