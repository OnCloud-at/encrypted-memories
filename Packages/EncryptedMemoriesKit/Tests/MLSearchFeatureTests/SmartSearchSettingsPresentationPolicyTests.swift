import Testing

@testable import MLSearchFeature

@Suite
struct SmartSearchSettingsPresentationPolicyTests {
    @Test func switchLooksOnWhileTheModelIsChosenBeforeAnythingIsStored() {
        #expect(SmartSearchSettingsPolicy.isToggleOn(isEnabled: false, isChoosingModel: true))
        #expect(SmartSearchSettingsPolicy.isToggleOn(isEnabled: true, isChoosingModel: false))
        #expect(!SmartSearchSettingsPolicy.isToggleOn(isEnabled: false, isChoosingModel: false))
    }

    @Test func turningOnShowsTheModelChoiceFirst() {
        #expect(content(isEnabled: false, isChoosingModel: false) == .off)
        #expect(content(isEnabled: false, isChoosingModel: true) == .modelChoice)
    }

    @Test func runningSmartSearchShowsItsStatus() {
        #expect(content(isEnabled: true, hasSelectedModel: true) == .status)
    }

    @Test func enabledSmartSearchWithoutAModelAsksForOne() {
        // For example after the catalog dropped the selected model.
        #expect(content(isEnabled: true, hasSelectedModel: false) == .modelChoice)
    }

    @Test func unsupportedDeviceCannotStartSmartSearch() {
        #expect(content(isSupported: false, isEnabled: false, isChoosingModel: true) == .unsupported)
    }

    @Test func enabledSmartSearchStaysManageableWhenSupportEnds() {
        #expect(content(isSupported: false, isEnabled: true, hasSelectedModel: true) == .status)
    }

    private func content(
        isSupported: Bool = true,
        isEnabled: Bool,
        hasSelectedModel: Bool = false,
        isChoosingModel: Bool = false
    ) -> SmartSearchSettingsContent {
        SmartSearchSettingsPolicy.content(
            isSupported: isSupported,
            isEnabled: isEnabled,
            hasSelectedModel: hasSelectedModel,
            isChoosingModel: isChoosingModel
        )
    }
}
