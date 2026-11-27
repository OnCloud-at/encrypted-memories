import MLSearchCore
import PhotosCore
import Testing
import TimelineCore

@testable import MLSearchFeature

/// The commit of the search field's text after a scope change, decided once for every host. Each host passes two
/// inputs: whether a suggestion answered the text before the change, and its own commit decision for the text in the
/// new scope. The macOS search menu decides with `commitDecision(for:content:snapshot:scope:)`, which can defer a
/// title until a refresh. The iOS search screen commits only a selected suggestion and decides with
/// `commitDecision(selected:for:scope:)`, which never defers.
///
/// The `before` functions below are the rules each host applied on its own before the rule was shared, copied from
/// those hosts. The traces run every combination of inputs that a host can produce and compare the outcomes.
@Suite struct SearchScopeChangeCommitTests {
    private static let photo = PhotoUID(volumeID: "v", nodeID: "0")

    private static func place(_ title: String) -> TimelineSearchSuggestion {
        TimelineSearchSuggestion(
            id: "place:\(title)", query: title, title: title, subtitle: nil, systemImage: "mappin", kind: .place,
            matchingUIDs: [photo], representativeUIDs: [photo])
    }

    /// A lexical suggestion carries no result set, so it never answers a text on its own.
    private static func lexical(_ title: String) -> TimelineSearchSuggestion {
        TimelineSearchSuggestion(id: "date:\(title)", query: title, title: title)
    }

    private static func kind(of decision: SmartSearchSuggestionCommitDecision) -> String {
        switch decision {
        case .text: "text"
        case .deferUntilRefresh: "deferred"
        case .structured: "structured"
        }
    }

    private static func decisions() -> [SmartSearchSuggestionCommitDecision] {
        [.text, .deferUntilRefresh, .structured(place("Berlin"))]
    }

    @Test func theRuleCommitsWhileASuggestionAnsweredOrOwnsTheText() {
        for answered in [false, true] {
            for decision in Self.decisions() {
                let outcome = SmartSearchDiscoveryModel.scopeChangeCommit(
                    suggestionAnswersText: answered, decision: decision)
                #expect(outcome.recommit == (answered || decision != .text))
                #expect(outcome.clearsSemanticQuery == (decision != .text))
            }
        }
    }

    // MARK: - macOS search menu

    /// The rule of `MainView.recommitSuggestionTitle()` before it was shared.
    private static func macBefore(
        activeCommittedSuggestion: Bool, decision: SmartSearchSuggestionCommitDecision
    ) -> SmartSearchScopeChangeCommit {
        guard activeCommittedSuggestion || decision != .text else {
            return SmartSearchScopeChangeCommit(recommit: false, clearsSemanticQuery: false)
        }
        return SmartSearchScopeChangeCommit(recommit: true, clearsSemanticQuery: decision != .text)
    }

    /// Every decision the menu's commit can make in every scope: typed text, the title of a shown suggestion, the
    /// title of a suggestion that waits for a refresh, and the title of a published suggestion after a current
    /// refresh dropped it. The outcome equals the menu's earlier rule in each of them.
    @Test func theSearchMenuKeepsEveryOutcome() {
        let shown = Self.place("Berlin")
        let waiting = Self.place("Paris")
        let dropped = Self.place("Rome")
        var reachedDecisions: Set<String> = []
        for scope in MLSearchScope.allCases {
            for (text, displayable, published, isCurrent) in [
                ("beach", [shown], [shown, waiting], false),
                ("Berlin", [shown], [shown], true),
                (" berlin ", [shown], [shown], false),
                ("Paris", [shown], [shown, waiting], false),
                ("Rome", [shown], [shown, dropped], true),
            ] {
                let decision = SmartSearchDiscoveryModel.commitDecision(
                    for: text, displayable: displayable, published: published, isCurrent: isCurrent, scope: scope)
                reachedDecisions.insert(Self.kind(of: decision))
                for answered in [false, true] {
                    #expect(
                        SmartSearchDiscoveryModel.scopeChangeCommit(suggestionAnswersText: answered, decision: decision)
                            == Self.macBefore(activeCommittedSuggestion: answered, decision: decision),
                        "scope \(scope), text \(text), answered \(answered)")
                }
            }
        }
        #expect(reachedDecisions.count == 3, "the trace reaches text, deferred and structured decisions")
    }

    // MARK: - iOS search screen

    /// The rule of the scope change in `MobileTimelineScreen` before it was shared: it committed again while the
    /// selected suggestion carried a result set and owned the text, and it never cleared the semantic query itself.
    private static func iOSBefore(
        selected: TimelineSearchSuggestion?, searchText: String
    ) -> SmartSearchScopeChangeCommit {
        let answers = selected.map { $0.matchingUIDs != nil && $0.owns(searchText: searchText) } ?? false
        return SmartSearchScopeChangeCommit(recommit: answers, clearsSemanticQuery: false)
    }

    /// The structured branch of `MobileTimelineScreen.scheduleSearchCommit` before it read the shared decision.
    private static func iOSCommitTookTheSuggestionBefore(
        selected: TimelineSearchSuggestion?, value: String, scope: MLSearchScope
    ) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selected, selected.matchingUIDs != nil, selected.owns(searchText: normalized),
            SmartSearchDiscoveryModel.usesSuggestionResults(in: scope)
        else { return false }
        return true
    }

    private static func iOSStates() -> [(selected: TimelineSearchSuggestion?, text: String)] {
        let berlin = Self.place("Berlin")
        let lexical = Self.lexical("Berlin")
        return [
            (nil, "Berlin"), (nil, "beach"), (nil, ""),
            (berlin, "Berlin"), (berlin, "  berlin\n"), (berlin, "Berlin Mitte"), (berlin, ""),
            (lexical, "Berlin"), (lexical, "beach"),
        ]
    }

    /// The screen's commit takes the selected suggestion in exactly the states it took it before.
    @Test func theSearchScreenCommitTakesTheSameSuggestion() {
        for scope in MLSearchScope.allCases {
            for (selected, text) in Self.iOSStates() {
                let decision = SmartSearchDiscoveryModel.commitDecision(
                    selected: selected, for: text.trimmingCharacters(in: .whitespacesAndNewlines), scope: scope)
                let tookTheSuggestion: Bool
                if case .structured(let suggestion) = decision {
                    tookTheSuggestion = true
                    #expect(suggestion == selected)
                } else {
                    tookTheSuggestion = false
                    #expect(decision == .text, "this decision never defers")
                }
                #expect(
                    tookTheSuggestion
                        == Self.iOSCommitTookTheSuggestionBefore(selected: selected, value: text, scope: scope),
                    "scope \(scope), text \(text)")
            }
        }
    }

    /// The screen commits again in exactly the states it did before. It now also clears the semantic query before
    /// that commit, but only in states where the commit itself takes the suggestion and clears the query as its first
    /// step, in the same update; a second clear changes nothing (`MLSmartSearchControllerTests`).
    @Test func theSearchScreenKeepsEveryOutcome() {
        for scope in MLSearchScope.allCases {
            for (selected, text) in Self.iOSStates() {
                let outcome = SmartSearchDiscoveryModel.scopeChangeCommit(
                    suggestionAnswersText: SmartSearchDiscoveryModel.answeringSuggestion(selected, for: text) != nil,
                    decision: SmartSearchDiscoveryModel.commitDecision(selected: selected, for: text, scope: scope))
                let before = Self.iOSBefore(selected: selected, searchText: text)
                #expect(outcome.recommit == before.recommit, "scope \(scope), text \(text)")
                if outcome.clearsSemanticQuery {
                    #expect(outcome.recommit)
                    #expect(Self.iOSCommitTookTheSuggestionBefore(selected: selected, value: text, scope: scope))
                } else {
                    #expect(outcome == before, "scope \(scope), text \(text)")
                }
            }
        }
    }
}
