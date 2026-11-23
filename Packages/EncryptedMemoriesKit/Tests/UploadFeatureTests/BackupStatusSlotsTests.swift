import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// The lines and the bar under the headline of the backup status: which of them show, and that an empty line keeps
/// its height. Both native rows read these values.
final class BackupStatusSlotsTests: XCTestCase {
    private func display(
        headlineKey: String = "backup.phase_uploading",
        isActive: Bool = true,
        accessory: BackupStatusPresentation.Accessory = .activity,
        progressFraction: Double? = 0.4,
        backedUp: Int = 4,
        total: Int = 10,
        remaining: Int = 6
    ) -> BackupStatusPresentation {
        var presentation = BackupStatusPresentation(
            headlineKey: headlineKey, isActive: isActive, accessory: accessory, progressFraction: progressFraction,
            backedUp: backedUp, total: total)
        presentation.remainingCount = remaining
        return presentation
    }

    func testAnEmptyLineHasTheHeightOfAFilledOneAndIsHidden() {
        let empty = BackupStatusPresentation.ReservedLine(text: nil)
        XCTAssertEqual(empty.displayText, "\u{00a0}")
        XCTAssertTrue(empty.isEmpty)

        let filled = BackupStatusPresentation.ReservedLine(text: "3 left")
        XCTAssertEqual(filled.displayText, "3 left")
        XCTAssertFalse(filled.isEmpty)
    }

    func testTheCountLineCarriesTheSubtitleAndIsEmptyBeforeTheFirstTotal() {
        let counting = display(backedUp: 4, total: 10)
        XCTAssertEqual(counting.reservedSubtitle.text, L10n.string("backup.progress_backed_up \(4) \(10)"))
        XCTAssertFalse(counting.reservedSubtitle.isEmpty)

        let noTotal = display(backedUp: 0, total: 0)
        XCTAssertNil(noTotal.localizedSubtitle)
        XCTAssertTrue(noTotal.reservedSubtitle.isEmpty)
    }

    func testTheLeftLineCarriesItsTextWhileWorkIsLeftAndIsEmptyOtherwise() {
        let working = display(remaining: 6)
        XCTAssertEqual(working.reservedLeftLine.text, L10n.string("backup.detail_left \(6)"))

        let nothingLeft = display(remaining: 0)
        XCTAssertTrue(nothingLeft.reservedLeftLine.isEmpty)

        let compact = display(headlineKey: "backup.phase_idle", isActive: false, accessory: .idle, remaining: 6)
        XCTAssertTrue(compact.reservedLeftLine.isEmpty, "the compact layout has no left line")
    }

    func testTheBarShowsItsFractionWhileThePassIsActive() {
        XCTAssertEqual(display(isActive: true, accessory: .activity, progressFraction: 0.4).progressBarFraction, 0.4)
    }

    func testTheBarShowsItsFractionWhilePausedEvenThoughNothingRuns() {
        let paused = display(
            headlineKey: "backup.phase_paused", isActive: false, accessory: .paused, progressFraction: 0.4)
        XCTAssertEqual(paused.progressBarFraction, 0.4)
    }

    func testTheBarIsHiddenWhenNothingRunsAndNothingIsPaused() {
        let waiting = display(
            headlineKey: "backup.phase_waiting_wifi", isActive: false, accessory: .waitingForWiFi,
            progressFraction: 0.4)
        XCTAssertNil(waiting.progressBarFraction)
    }

    func testTheBarIsHiddenWithoutAFraction() {
        XCTAssertNil(display(isActive: true, accessory: .activity, progressFraction: nil).progressBarFraction)
        let pausedWithoutFraction = display(
            headlineKey: "backup.phase_paused", isActive: false, accessory: .paused, progressFraction: nil)
        XCTAssertNil(pausedWithoutFraction.progressBarFraction)
    }
}
