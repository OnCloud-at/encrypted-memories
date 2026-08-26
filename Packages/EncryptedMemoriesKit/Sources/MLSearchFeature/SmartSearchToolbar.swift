import MLSearchCore
import PhotosCore
import SwiftUI

public struct SmartSearchSuggestionItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let query: String

    public init(id: String, title: String, query: String) {
        self.id = id
        self.title = title
        self.query = query
    }
}

/// Shared native toolbar-search presentation. Semantic search tabs attach `.searchable` to the search tab's
/// own navigation content and reuse only `smartSearchScopes`; the owning `TabView` keeps the semantic role.
public extension View {
    func smartSearchToolbar(
        text: Binding<String>,
        scope: Binding<MLSearchScope>,
        availableScopes: [MLSearchScope],
        isEnabled: Bool,
        isVisible: Bool = true,
        placement: SearchFieldPlacement = .automatic,
        prompt: Text,
        recentSearches: [String] = [],
        suggestions: [SmartSearchSuggestionItem] = [],
        onClearRecentSearches: @escaping () -> Void = {}
    ) -> some View {
        modifier(
            SmartSearchToolbarModifier(
                text: text,
                scope: scope,
                availableScopes: availableScopes,
                isEnabled: isEnabled,
                isVisible: isVisible,
                placement: placement,
                prompt: prompt,
                recentSearches: recentSearches,
                suggestions: suggestions,
                onClearRecentSearches: onClearRecentSearches
            ))
    }

    func smartSearchScopes(
        scope: Binding<MLSearchScope>,
        availableScopes: [MLSearchScope],
        isEnabled: Bool
    ) -> some View {
        modifier(
            SmartSearchScopesModifier(
                scope: scope,
                availableScopes: availableScopes,
                isEnabled: isEnabled
            ))
    }
}

private struct SmartSearchToolbarModifier: ViewModifier {
    @Binding var text: String
    @Binding var scope: MLSearchScope
    @State private var isPresented = false
    let availableScopes: [MLSearchScope]
    let isEnabled: Bool
    let isVisible: Bool
    let placement: SearchFieldPlacement
    let prompt: Text
    let recentSearches: [String]
    let suggestions: [SmartSearchSuggestionItem]
    let onClearRecentSearches: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
            searchableContent(content)
                .searchToolbarBehavior(.minimize)
                .toolbar(removing: isVisible ? nil : .search)
        #else
            searchableContent(content)
                .toolbar(removing: isVisible ? nil : .search)
        #endif
    }

    private func searchableContent(_ content: Content) -> some View {
        content
            .searchable(
                text: $text,
                isPresented: $isPresented,
                placement: placement,
                prompt: prompt
            )
            .smartSearchScopes(
                scope: $scope,
                availableScopes: availableScopes,
                isEnabled: isEnabled
            )
            .searchSuggestions {
                if !recentSearches.isEmpty {
                    Section(L10n.string("search.recent")) {
                        ForEach(recentSearches, id: \.self) { query in
                            Label(query, systemImage: "clock.arrow.circlepath")
                                .searchCompletion(query)
                        }
                        Button(L10n.string("search.clear"), action: onClearRecentSearches)
                    }
                }
                if !suggestions.isEmpty {
                    Section(L10n.string("search.suggestions")) {
                        ForEach(suggestions) { suggestion in
                            Label(suggestion.title, systemImage: "magnifyingglass")
                                .searchCompletion(suggestion.query)
                        }
                    }
                }
            }
            .onChange(of: text) { oldQuery, newQuery in
                reconcileSearchQueryChange(from: oldQuery, to: newQuery)
            }
    }

    private func reconcileSearchQueryChange(from oldQuery: String, to newQuery: String) {
        apply(
            SmartSearchToolbarPresentationPolicy.queryChangeAction(
                oldQuery: oldQuery,
                newQuery: newQuery
            ))
    }

    private func apply(_ action: SmartSearchToolbarPresentationAction) {
        switch action {
        case .retain:
            break
        case .dismiss(let clearText):
            if clearText, !text.isEmpty {
                text = ""
            }
            isPresented = false
            resetSearchScopes()
        }
    }

    private func resetSearchScopes() {
        scope = .all
    }
}

private struct SmartSearchScopesModifier: ViewModifier {
    @Binding var scope: MLSearchScope
    let availableScopes: [MLSearchScope]
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            // Search scopes are the system's visible refinement control. On-text-entry activation
            // keeps the broad search field quiet until it is used, then presents the native
            // platform scope bar without relying on a deletable token or a late AppKit mutation.
            .searchScopes($scope, activation: .onTextEntry) {
                if availableScopes.count > 1 {
                    ForEach(availableScopes, id: \.self) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    scope = .all
                }
            }
            .onChange(of: availableScopes) { _, scopes in
                if !scopes.contains(scope) {
                    scope = .all
                }
            }
            .onChange(of: scope) { _, selectedScope in
                if !availableScopes.contains(selectedScope) {
                    scope = .all
                }
            }
    }
}

enum SmartSearchToolbarPresentationAction: Equatable {
    case retain
    case dismiss(clearText: Bool)
}

enum SmartSearchToolbarPresentationPolicy {
    static func queryChangeAction(
        oldQuery: String,
        newQuery: String
    ) -> SmartSearchToolbarPresentationAction {
        let hadQuery = !oldQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasQuery = !newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hadQuery && !hasQuery ? .dismiss(clearText: false) : .retain
    }
}

private extension MLSearchScope {
    var localizedTitle: String {
        switch self {
        case .all: MLSmartSearchPresentation.productName
        case .semantic: L10n.string("mlsearch.scope_semantic")
        case .text: L10n.string("mlsearch.scope_text")
        case .documents: L10n.string("mlsearch.scope_documents")
        case .barcodes: L10n.string("mlsearch.scope_barcodes")
        case .similar: L10n.string("mlsearch.scope_similar")
        }
    }
}
