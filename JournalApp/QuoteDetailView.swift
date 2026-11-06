// The third column when Quotes is picked: one quote, ready to read or change. Changes save
// themselves, the same as pages.

import JournalCore
import SwiftUI

struct QuoteDetailView: View {
    let model: JournalModel

    var body: some View {
        if let id = model.selectedQuoteId, let quote = model.loadQuote(id: id) {
            // `.id` gives each quote a fresh view, so one quote's typing can't leak into another.
            QuoteEditor(quote: quote, model: model)
                .id(id)
        } else {
            ContentUnavailableView("Choose a quote", systemImage: "text.quote")
        }
    }
}

private struct QuoteEditor: View {
    let quote: Quote
    let model: JournalModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: Draft
    @State private var saved: Draft
    @State private var isConfirmingDelete = false

    // The fields as typed. Tags stay as one piece of text until saving, so tidying them can't
    // move the caret or remove the comma someone is partway through typing.
    private struct Draft: Hashable {
        var text: String
        var author: String
        var source: String
        var tags: String
        var sectionId: UUID?
    }

    init(quote: Quote, model: JournalModel) {
        self.quote = quote
        self.model = model
        let draft = Draft(
            text: quote.text,
            author: quote.author,
            source: quote.source,
            tags: quote.tags.joined(separator: ", "),
            sectionId: quote.sectionId
        )
        _draft = State(initialValue: draft)
        _saved = State(initialValue: draft)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TextField("Quote", text: $draft.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.title2, design: .serif))
                fields
                sourcePageLink
                Text("Saved \(quote.createdAt.formatted(.dateTime.month(.wide).day().year()))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            #if os(iOS)
            // On iPhone the list isn't showing, so its random button can't be reached from here.
            ToolbarItem(placement: .primaryAction) {
                Button("Random quote", systemImage: "dice", action: model.showRandomQuote)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(currentQuote.textWithAttribution) }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Delete", systemImage: "trash") { isConfirmingDelete = true }
            }
        }
        .confirmationDialog("Delete this quote?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteQuote(id: quote.id) }
        }
        // Restarts with each change, so the save happens once typing pauses.
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { save() }
        }
        .onDisappear(perform: save)
        .onChange(of: scenePhase) {
            if scenePhase != .active { save() }
        }
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            field("Author", text: $draft.author, prompt: "Who said it")
            field("Source", text: $draft.source, prompt: "Book, talk or film")
            field("Tags", text: $draft.tags, prompt: "Separated by commas")
            GridRow {
                label("Section")
                Menu(sectionName) {
                    Button("None") { draft.sectionId = nil }
                    ForEach(model.tree.sections) { section in
                        Button(model.tree.path(toSection: section.id)) { draft.sectionId = section.id }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .foregroundStyle(draft.sectionId == nil ? .secondary : .primary)
                .fixedSize()
            }
        }
    }

    private func field(_ name: String, text: Binding<String>, prompt: String) -> some View {
        GridRow {
            label(name)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
        }
    }

    private func label(_ name: String) -> some View {
        Text(name)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private var sectionName: String {
        model.tree.sections.first { $0.id == draft.sectionId }?.name ?? "None"
    }

    // Hidden if the page has since been deleted.
    @ViewBuilder
    private var sourcePageLink: some View {
        if let pageId = quote.pageId, let page = model.loadPage(id: pageId) {
            Button {
                save()
                model.openPage(id: page.id, sectionId: page.sectionId)
            } label: {
                Label("From \(page.title.isEmpty ? "Untitled" : page.title)", systemImage: "doc.text")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    private var currentQuote: Quote {
        var updated = quote
        updated.text = draft.text
        updated.author = draft.author
        updated.source = draft.source
        updated.tags = Quote.parseTags(draft.tags)
        updated.sectionId = draft.sectionId
        return updated
    }

    private func save() {
        guard draft != saved else { return }
        // A quote can't be blank. If the text was cleared, the last words saved are kept.
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // It may have just been deleted, and saving would otherwise bring it back to life.
        guard model.loadQuote(id: quote.id) != nil else { return }
        saved = draft
        model.updateQuote(currentQuote)
    }
}
