import Testing

@testable import MLSearchFeature

@Suite
struct SmartSearchSettingsPresentationPolicyTests {
    @Test func switchLooksOnWhileSmartSearchStartsBeforeAnythingIsStored() {
        #expect(SmartSearchSettingsPolicy.isToggleOn(isEnabled: false, isStarting: true))
        #expect(SmartSearchSettingsPolicy.isToggleOn(isEnabled: true, isStarting: false))
        #expect(!SmartSearchSettingsPolicy.isToggleOn(isEnabled: false, isStarting: false))
    }

    @Test func turningOnStartsWithoutAModelChoice() {
        #expect(content(isEnabled: false, isStarting: false) == .off)
        #expect(content(isEnabled: false, isStarting: true) == .starting)
    }

    @Test func runningSmartSearchShowsItsStatus() {
        #expect(content(isEnabled: true, hasSelectedModel: true) == .status)
    }

    @Test func enabledSmartSearchWithoutAModelAsksForOne() {
        // For example after the catalog dropped the selected model.
        #expect(content(isEnabled: true, hasSelectedModel: false) == .modelChoice)
    }

    @Test func unsupportedDeviceCannotStartSmartSearch() {
        #expect(content(isSupported: false, isEnabled: false, isStarting: true) == .unsupported)
    }

    @Test func enabledSmartSearchStaysManageableWhenSupportEnds() {
        #expect(content(isSupported: false, isEnabled: true, hasSelectedModel: true) == .status)
    }

    @Test func onlyReplacingAServingModelAsksFirst() {
        #expect(SmartSearchSettingsPolicy.asksBeforeSwitching(hasActiveModel: true))
        #expect(!SmartSearchSettingsPolicy.asksBeforeSwitching(hasActiveModel: false))
    }

    private func content(
        isSupported: Bool = true,
        isEnabled: Bool,
        hasSelectedModel: Bool = false,
        isStarting: Bool = false
    ) -> SmartSearchSettingsContent {
        SmartSearchSettingsPolicy.content(
            isSupported: isSupported,
            isEnabled: isEnabled,
            hasSelectedModel: hasSelectedModel,
            isStarting: isStarting
        )
    }
}
