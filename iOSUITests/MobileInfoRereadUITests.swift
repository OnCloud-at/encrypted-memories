import XCTest

/// The viewer's Info on the offline fixture account reads the photo details a second time before it shows a failure.
/// `-EncryptedMemoriesInfoReadScenario` makes the fixture backend fail the reads and log every read, so the test counts
/// the reads of the photo that it opened. The viewer also reads its neighbors once for their titles; those reads never
/// repeat, so the opened photo is the one with the highest count.
final class MobileInfoRereadUITests: XCTestCase {
    private var app: XCUIApplication!
    private var readLog: URL!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApplication.make()
        readLog = FileManager.default.temporaryDirectory.appendingPathComponent("info-reads-\(UUID().uuidString).log")
    }

    override func tearDown() {
        app.terminate()
        try? FileManager.default.removeItem(at: readLog)
    }

    private func launch(_ scenario: String) {
        app.launchArguments = [
            "-EncryptedMemoriesUITestFixture",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-EncryptedMemoriesInfoReadScenario", scenario, readLog.path,
        ]
        app.launch()
    }

    /// The reads per photo so far.
    private func reads() -> [String: Int] {
        let text = (try? String(contentsOf: readLog, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").reduce(into: [:]) { counts, line in counts[String(line), default: 0] += 1 }
    }

    private func openFirstPhoto() throws {
        let column = try app.verticalTabColumn()
        try app.visiblePhoto(beside: column).tap()
        XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 30), "the viewer shows no Info button")
    }

    private var failure: XCUIElement { app.staticTexts["Info Unavailable"] }

    /// A file name that the fixture gives to every photo: the Info shows it once the details loaded.
    private var fileName: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '.jpg'")).firstMatch
    }

    /// Waits until the details show and fails at once if the Info shows the failure on the way.
    private func waitForDetailsWithoutAFailure() {
        let deadline = Date().addingTimeInterval(40)
        while !fileName.exists, Date() < deadline {
            XCTAssertFalse(failure.exists, "the Info showed the failure that one more read clears")
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(fileName.exists, "the Info shows no details after the repeat")
        XCTAssertFalse(app.buttons["Try again"].exists)
    }

    /// The first read of the photo is slow and fails. The person opens the Info while it runs; the read decides when
    /// it ends, so the Info repeats it and never shows the failure.
    func testAnInfoThatOpensWhileTheFirstReadRunsRepeatsItInsteadOfShowingTheFailure() throws {
        launch("slowFirstReadFails")
        try openFirstPhoto()
        app.buttons["Info"].tap()

        waitForDetailsWithoutAFailure()

        let counts = reads()
        XCTAssertEqual(counts.values.filter { $0 == 2 }.count, 1, "exactly the opened photo is read twice: \(counts)")
        XCTAssertTrue(counts.values.allSatisfy { $0 <= 2 }, "no photo is read more than twice: \(counts)")
    }

    /// The first read fails at once, before the person opens the Info. The Info that opens afterwards repeats the
    /// read and never shows the failure.
    func testAnInfoThatOpensAfterTheFirstReadFailedRepeatsItInsteadOfShowingTheFailure() throws {
        launch("firstReadFails")
        try openFirstPhoto()
        let deadline = Date().addingTimeInterval(30)
        while reads().isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertFalse(reads().isEmpty, "the viewer read no photo details")
        app.buttons["Info"].tap()

        waitForDetailsWithoutAFailure()

        let counts = reads()
        XCTAssertEqual(counts.values.filter { $0 == 2 }.count, 1, "exactly the opened photo is read twice: \(counts)")
        XCTAssertTrue(counts.values.allSatisfy { $0 <= 2 }, "no photo is read more than twice: \(counts)")
    }

    /// The first three reads fail: the title read, the silent repeat and the person's own Try again. The Info shows
    /// the failure after the repeat, and again at once after Try again, without a second silent repeat behind it.
    func testTryAgainAfterTheSilentRepeatShowsItsOwnResultWithoutAnotherRepeat() throws {
        launch("firstThreeReadsFail")
        try openFirstPhoto()
        app.buttons["Info"].tap()

        let tryAgain = app.buttons["Try again"]
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 40), "the Info shows no Try again after both reads failed")
        XCTAssertTrue(failure.exists)
        let before = reads()
        XCTAssertEqual(before.values.filter { $0 == 2 }.count, 1, "the opened photo is read twice first: \(before)")
        XCTAssertTrue(before.values.allSatisfy { $0 <= 2 }, "no photo is read more than twice: \(before)")

        tryAgain.tap()

        // The person's read is the third read of the photo. A silent repeat would keep the spinner for three seconds
        // before it, so the failure must be back within two seconds of that read.
        let deadline = Date().addingTimeInterval(40)
        while reads().values.max() != 3, Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertEqual(reads().values.max(), 3, "Try again did not read the photo")
        XCTAssertTrue(failure.waitForExistence(timeout: 2), "the failure did not return at once after Try again")
        XCTAssertTrue(app.buttons["Try again"].exists)
        let after = reads()
        XCTAssertEqual(
            after.values.filter { $0 == 3 }.count, 1, "Try again reads the opened photo exactly once: \(after)")
        XCTAssertTrue(after.values.allSatisfy { $0 <= 3 }, "no photo is read more than three times: \(after)")
    }
}
