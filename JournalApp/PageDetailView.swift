// The third column: the open page, with its title, format bar and editor.

import JournalCore
import JournalEditor
import SwiftUI

struct PageDetailView: View {
    let model: JournalModel

    var body: some View {
        if let page = model.selectedPage {
            // `.id` gives each page its own fresh view, so one page's typing can't leak into another.
            PageContent(page: page, model: model)
                .id(page.id)
        } else {
            ContentUnavailableView("Choose a page", systemImage: "doc.richtext")
        }
    }
}

// Connects an open editor to the database. Saving on every keystroke would be wasteful, so it
// waits for a short pause in typing. Leaving the page saves right away.
@MainActor
private final class PageSession {
    let controller: EditorController
    private let save: (PageDocument) -> Void
    private var hasChanges = false
    private var waitingSave: Task<Void, Never>?

    init(document: PageDocument, save: @escaping (PageDocument) -> Void) {
        controller = EditorController(document: document)
        self.save = save
        controller.onChange = { [weak self] in self?.pageChanged() }
    }

    private func pageChanged() {
        hasChanges = true
        waitingSave?.cancel()
        waitingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        waitingSave?.cancel()
        guard hasChanges else { return }
        hasChanges = false
        save(controller.document)
    }
}

private struct PageContent: View {
    let page: Page
    let model: JournalModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appTheme) private var theme
    @State private var title: String
    @State private var session: PageSession?
    @State private var couldNotOpen = false
    @State private var isPickingQuote = false
    @FocusState private var isTitleFocused: Bool

    init(page: Page, model: JournalModel) {
        self.page = page
        self.model = model
        _title = State(initialValue: page.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            if let session {
                formatBar(session)
                Divider()
            }
            #endif
            pageColumn
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // Sitting in the bottom safe area is what keeps the bar just above the keyboard.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let session {
                formatBar(session)
            }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Find on page", systemImage: "text.magnifyingglass") {
                    session?.controller.showFind()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(session == nil)
            }
        }
        .sheet(isPresented: $isPickingQuote) {
            QuotePickerView(model: model) { quote in
                session?.controller.insertBlocks(quote.blocks)
            }
        }
        .task { open() }
        .onDisappear {
            session?.saveNow()
            model.pageClosed(id: page.id)
        }
        // The system can close a backgrounded app at any time, so save before that can happen.
        .onChange(of: scenePhase) {
            if scenePhase != .active { session?.saveNow() }
        }
    }

    private func formatBar(_ session: PageSession) -> some View {
        FormatBar(
            controller: session.controller,
            background: theme.background(.row),
            onInsertQuote: { isPickingQuote = true },
            onSaveSelectionAsQuote: { text in
                model.capture = QuoteCapture(text: text, sectionId: page.sectionId, pageId: page.id)
            }
        )
    }

    private var pageColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let session {
                RichTextEditor(controller: session.controller)
            } else if couldNotOpen {
                ContentUnavailableView(
                    "This page couldn't be opened",
                    systemImage: "exclamationmark.triangle",
                    description: Text("It hasn't been changed. It may need a newer version of the app.")
                )
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Untitled", text: $title, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
                .focused($isTitleFocused)
                .onChange(of: title) { model.renamePage(id: page.id, title: title) }
            Text(page.createdAt, format: .dateTime.weekday(.wide).month(.wide).day().year())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func open() {
        guard session == nil else { return }
        guard let document = model.loadDocument(pageId: page.id) else {
            couldNotOpen = true
            return
        }
        let pageId = page.id
        let newSession = PageSession(document: document) { [model] in
            model.saveDocument($0, pageId: pageId)
        }
        session = newSession
        model.pageOpened(id: pageId) { [weak newSession] in newSession?.saveNow() }
        // A brand new page is ready for typing straight away.
        isTitleFocused = page.title.isEmpty
    }
}
