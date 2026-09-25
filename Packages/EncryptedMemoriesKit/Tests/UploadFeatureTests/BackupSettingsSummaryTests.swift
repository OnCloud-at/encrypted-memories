import XCTest

@testable import UploadCore

final class BackupSettingsSummaryTests: XCTestCase {
    private func display(_ accessory: BackupStatusPresentation.Accessory) -> BackupStatusPresentation {
        BackupStatusPresentation(
            headlineKey: "backup.phase_idle", isActive: accessory == .activity, accessory: accessory,
            progressFraction: nil)
    }

    private func summary(
        isAvailable: Bool = true, isEnabled: Bool = true, isUserPaused: Bool = false,
        _ accessory: BackupStatusPresentation.Accessory = .idle
    ) -> BackupSettingsSummary {
        BackupSettingsSummary(
            isAvailable: isAvailable, isEnabled: isEnabled, isUserPaused: isUserPaused, display: display(accessory))
    }

    func testUnavailableBackupWinsOverStoredSettings() {
        XCTAssertEqual(summary(isAvailable: false, isEnabled: true, isUserPaused: true, .activity), .unavailable)
    }

    func testDisabledBackupIsOffWhateverTheLastStatus() {
        XCTAssertEqual(summary(isEnabled: false, .attention), .off)
        XCTAssertEqual(summary(isEnabled: false, isUserPaused: true), .off)
    }

    func testUserPauseWinsOverTheStatusOfTheStoppingPass() {
        XCTAssertEqual(summary(isUserPaused: true, .activity), .paused)
        XCTAssertEqual(summary(isUserPaused: true, .attention), .paused)
    }

    func testEnabledBackupNamesTheDisplayedState() {
        XCTAssertEqual(summary(.activity), .backingUp)
        XCTAssertEqual(summary(.paused), .paused)
        XCTAssertEqual(summary(.waiting), .waiting)
        XCTAssertEqual(summary(.attention), .incomplete)
        XCTAssertEqual(summary(.idle), .on)
        XCTAssertEqual(summary(.success), .on)
        XCTAssertEqual(summary(.notice), .on)
    }

    func testOnlyIncompleteBackupAsksForAttention() {
        let states: [BackupSettingsSummary] = [.unavailable, .off, .on, .backingUp, .paused, .waiting, .incomplete]
        XCTAssertEqual(states.filter(\.needsAttention), [.incomplete])
    }
}
