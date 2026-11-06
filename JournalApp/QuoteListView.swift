// The second column when Quotes is picked: the library, with its search box and filter.

import JournalCore
import SwiftUI

struct QuoteListView: View {
    @Bindable var model: JournalModel

    private var library: QuoteLibrary { model.quoteLibrary }

    private var isNarrowed: Bool {
        !model.quoteQuery.search.isEmpty || model.quoteQuery.filter != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if let filter = model.quoteQuery.filter {
                activeFilter(filter)
            }
            quoteList
        }
        .navigationTitle("Quotes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Random quote", systemImage: "dice", action: model.showRandomQuote)
                    .disabled(library.quotes.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New quote", systemImage: "square.and.pencil", action: model.beginQuote)
            }
        }
    }

    // MARK: Search and filter

    private var searchBar: some View {
        HStack(spacing: 8) {
            SearchField(prompt: "Text, author or tag", text: $model.quoteQuery.search)
            filterMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterMenu: some View {
        Menu {
            if !library.tags.isEmpty {
                Menu("Tag") {
                    ForEach(library.tags, id: \.self) { tag in
                        Button(tag) { model.quoteQuery.filter = .tag(tag) }
                    }
                }
            }
            if !library.authors.isEmpty {
                Menu("Author") {
                    ForEach(library.authors, id: \.self) { author in
                        Button(author) { model.quoteQuery.filter = .author(author) }
                    }
                }
            }
            if !filterSections.isEmpty {
                Menu("Section") {
                    ForEach(filterSections) { section in
                        Button(section.name) { model.quoteQuery.filter = .section(section.id) }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .accessibilityLabel("Filter")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(library.tags.isEmpty && library.authors.isEmpty && filterSections.isEmpty)
    }

    // A quote can outlive the section it was filed in, so deleted sections are left out here.
    private var filterSections: [NoteSection] {
        model.tree.sections.filter { library.sectionIds.contains($0.id) }
    }

    private func activeFilter(_ filter: QuoteFilter) -> some View {
        HStack(spacing: 6) {
            Text(filterName(filter))
                .font(.caption)
                .lineLimit(1)
            Button("Remove filter", systemImage: "xmark") {
                model.quoteQuery.filter = nil
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.caption2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func filterName(_ filter: QuoteFilter) -> String {
        switch filter {
        case .tag(let tag): "Tag: \(tag)"
        case .author(let author): "Author: \(author)"
        case .section(let id): "Section: \(model.tree.sections.first { $0.id == id }?.name ?? "Deleted")"
        }
    }

    // MARK: List

    @ViewBuilder
    private var quoteList: some View {
        if library.quotes.isEmpty {
            if isNarrowed {
                ContentUnavailableView.search
                    .frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Save your first quote", systemImage: "text.quote")
                } actions: {
                    Button("New quote", action: model.beginQuote)
                }
                .frame(maxHeight: .infinity)
            }
        } else {
            List(selection: $model.selectedQuoteId) {
                ForEach(library.quotes) { quote in
                    QuoteRow(quote: quote)
                        .tag(quote.id)
                        .themedRow(.page)
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(quote.textWithAttribution) }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.deleteQuote(id: quote.id)
                            }
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.deleteQuote(id: quote.id)
                            }
                        }
                }
            }
        }
    }
}

struct QuoteRow: View {
    let quote: Quote

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(quote.text)
                .lineLimit(3)
            if !quote.attribution.isEmpty {
                Text(quote.attribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !quote.tags.isEmpty {
                Text(quote.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

extension Quote {
    // How a quote reads outside the app.
    var textWithAttribution: String {
        attribution.isEmpty ? text : "\(text)\n— \(attribution)"
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
