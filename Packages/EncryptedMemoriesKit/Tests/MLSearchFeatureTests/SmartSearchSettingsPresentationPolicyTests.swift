import Testing

@testable import MLSearchFeature

@Suite
struct SmartSearchSettingsPresentationPolicyTests {
    @Test func oldEnabledStateWithoutModelDisplaysAsOff() {
        #expect(
            SmartSearchVisualSearchPresentationPolicy.isToggleOn(
                isEnabled: true,
                hasSelectedModel: false,
                isChoosingInitialModel: false
            ) == false
        )
    }

    @Test func toggleDisplaysAsOnOnlyWithAnEnabledSelectedModel() {
        #expect(
            SmartSearchVisualSearchPresentationPolicy.isToggleOn(
                isEnabled: true,
                hasSelectedModel: true,
                isChoosingInitialModel: false
            )
        )
        #expect(
            SmartSearchVisualSearchPresentationPolicy.isToggleOn(
                isEnabled: false,
                hasSelectedModel: true,
                isChoosingInitialModel: false
            ) == false
        )
    }

    @Test func initialInlineModelChoiceKeepsToggleVisuallyOnUntilSelection() {
        #expect(
            SmartSearchVisualSearchPresentationPolicy.isToggleOn(
                isEnabled: false,
                hasSelectedModel: false,
                isChoosingInitialModel: true
            )
        )
    }

    @Test func firstVisualSearchEnableShowsExistingInlineModelChoices() {
        #expect(
            SmartSearchVisualSearchPresentationPolicy.enableAction(hasSelectedModel: false)
                == .showInlineModelChoices
        )
    }

    @Test func visualSearchReenableUsesExistingModelSelection() {
        #expect(
            SmartSearchVisualSearchPresentationPolicy.enableAction(hasSelectedModel: true)
                == .enableSelectedModel
        )
    }
}
