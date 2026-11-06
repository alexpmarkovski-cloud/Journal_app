// The results for the search box, grouped into quotes and pages.

import JournalCore
import SwiftUI

struct SearchResultsView: View {
    let model: JournalModel

    private var results: SearchResults { model.searchResults }

    var body: some View {
        if results.isEmpty {
            noResults
                .frame(maxHeight: .infinity)
        } else {
            List(selection: Binding(get: { model.activeResultId }, set: model.openResult)) {
                if !results.quotes.isEmpty {
                    Section(heading("Quotes", count: results.quotes.count)) {
                        ForEach(results.quotes) { result in
                            quoteRow(result)
                                .tag(result.id)
                                .themedRow()
                        }
                    }
                }
                if !results.pages.isEmpty {
                    Section(heading("Pages", count: results.pages.count)) {
                        ForEach(results.pages) { result in
                            pageRow(result)
                                .tag(result.id)
                                .themedRow()
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    @ViewBuilder
    private var noResults: some View {
        if model.searchScope == .everything {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            ContentUnavailableView {
                Label("Nothing here", systemImage: "magnifyingglass")
            } description: {
                Text("No results for \"\(model.searchText)\" in \(model.searchScopeName).")
            } actions: {
                Button("Search everything") { model.searchScope = .everything }
            }
        }
    }

    private func heading(_ name: String, count: Int) -> String {
        count == AppDatabase.searchResultLimit ? "\(name) (first \(count))" : name
    }

    private func quoteRow(_ result: QuoteSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(highlighted(result.snippet))
                .lineLimit(4)
            if !result.author.isEmpty {
                Text(result.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func pageRow(_ result: PageSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if result.title.isEmpty {
                    Text("Untitled")
                } else {
                    Text(highlighted(result.title))
                }
            }
            .lineLimit(1)
            if !result.snippet.isEmpty {
                Text(highlighted(result.snippet))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(model.tree.path(toSection: result.sectionId))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func highlighted(_ parts: [SnippetPart]) -> AttributedString {
        parts.reduce(into: AttributedString()) { text, part in
            var piece = AttributedString(part.text)
            if part.isMatch {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = .accentColor
            }
            text.append(piece)
        }
    }
}
