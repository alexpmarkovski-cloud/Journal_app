// Holds what the screens show and handles what they ask for.
//
// Screens never write to the database and then refresh themselves. They ask this model to
// make a change, the database reports the new data, and SwiftUI redraws whatever used it.
// So there's one direction of flow and the screens can't get out of step with the database.

import Foundation
import JournalCore
import Observation
import SwiftUI

// What can be picked in the first column.
enum SidebarItem: Hashable {
    case quotes
    case section(UUID)
}

// What the new quote window starts with. Saving from a page fills in all of it.
struct QuoteCapture: Identifiable {
    let id = UUID()
    var text = ""
    var sectionId: UUID?
    var pageId: UUID?
}

// The search box's text and where it's looking, so a change to either restarts the search.
struct SearchQuery: Hashable {
    var text: String
    var scope: SearchScope
}

// The library's search and filter together, so a change to either restarts the library's watch.
struct QuoteQuery: Hashable {
    var search = ""
    var filter: QuoteFilter?
}

@MainActor
@Observable
final class JournalModel {
    private(set) var tree = JournalTree()
    private(set) var pages: [Page] = []
    private(set) var hasLoadedTree = false
    var errorMessage: String?

    var sidebarSelection: SidebarItem? {
        didSet {
            guard sidebarSelection != oldValue else { return }
            selectedPageId = nil
            pages = []
            if sidebarSelection != .quotes {
                selectedQuoteId = nil
            }
            if let selectedSection {
                lastSections[selectedSection.notebookId] = selectedSection.id
            }
        }
    }
    var selectedPageId: UUID?

    var selectedSectionId: UUID? {
        get {
            if case .section(let id) = sidebarSelection { id } else { nil }
        }
        set {
            sidebarSelection = newValue.map(SidebarItem.section)
        }
    }

    // Which screen shows on iPhone, where only one column fits. Opening a search result jumps
    // straight to the last one. The Mac shows all three, so it ignores this.
    var compactColumn = NavigationSplitViewColumn.sidebar

    var searchText = ""
    var searchScope = SearchScope.everything
    private(set) var searchResults = SearchResults()

    private(set) var quoteLibrary = QuoteLibrary()
    var quoteQuery = QuoteQuery()
    var selectedQuoteId: UUID?
    var capture: QuoteCapture?

    private(set) var expandedItems: Set<UUID>

    // The notebook whose sections the sidebar shows. Like a physical book, one is open at a time.
    private(set) var openNotebookId: UUID? {
        didSet {
            defaults.set(openNotebookId?.uuidString, forKey: Self.openNotebookKey)
        }
    }
    var isShowingNotebooks = false
    // The section last used in each notebook, for going back to it on Mac.
    private var lastSections: [UUID: UUID] = [:]

    // Saves whatever the open page is still waiting to save.
    private var openPageSavers: [UUID: () -> Void] = [:]

    private let database: AppDatabase
    private let defaults: UserDefaults
    private static let expandedKey = "expandedTreeItems"
    private static let openNotebookKey = "openNotebook"

    init(database: AppDatabase, defaults: UserDefaults = .standard) {
        self.database = database
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.expandedKey) ?? []
        expandedItems = Set(saved.compactMap(UUID.init(uuidString:)))
        openNotebookId = defaults.string(forKey: Self.openNotebookKey).flatMap(UUID.init(uuidString:))
    }

    var openNotebook: Notebook? {
        tree.notebooks.first { $0.id == openNotebookId }
    }

    // What the sidebar lists: the open notebook's contents.
    var rows: [TreeRow] {
        guard let openNotebookId else { return [] }
        return tree.rows(inNotebook: openNotebookId, expanded: expandedItems)
    }

    var selectedSection: NoteSection? {
        tree.sections.first { $0.id == selectedSectionId }
    }

    var selectedPage: Page? {
        pages.first { $0.id == selectedPageId }
    }

    // MARK: Watching the database

    func watchTree() async {
        do {
            for try await newTree in database.treeUpdates() {
                tree = newTree
                hasLoadedTree = true
                // The open notebook may have just been deleted, or this may be the first one.
                if !newTree.notebooks.contains(where: { $0.id == openNotebookId }) {
                    openNotebookId = newTree.notebooks.first?.id
                }
                // The selected section may have just been deleted or moved to another notebook.
                if let id = selectedSectionId {
                    let section = newTree.sections.first { $0.id == id }
                    if section?.notebookId != openNotebookId {
                        sidebarSelection = nil
                    }
                }
                // So is the place being searched.
                if case .item(let ref) = searchScope, newTree.name(of: ref) == nil {
                    searchScope = .everything
                }
            }
        } catch {
            errorMessage = "Couldn't load your notebooks. Quit the app and open it again."
        }
    }

    func watchPages() async {
        guard let sectionId = selectedSectionId else { return }
        do {
            for try await newPages in database.pageUpdates(sectionId: sectionId) {
                // A result can already be on its way when a different section is picked. Using
                // it would close a page that was just opened from search.
                guard sectionId == selectedSectionId else { return }
                pages = newPages
                if let id = selectedPageId, !newPages.contains(where: { $0.id == id }) {
                    selectedPageId = nil
                }
            }
        } catch {
            errorMessage = "Couldn't load these pages. Quit the app and open it again."
        }
    }

    // Runs again every time the search box changes, and the last run is cancelled by then. The
    // short wait means fast typing only searches once the typing pauses.
    func watchSearch() async {
        let query = searchQuery
        guard isSearching else {
            searchResults = SearchResults()
            return
        }
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        do {
            for try await results in database.searchUpdates(query.text, in: query.scope) {
                searchResults = results
            }
        } catch {
            if !Task.isCancelled { errorMessage = "Couldn't search your journal. Try again." }
        }
    }

    func watchQuoteLibrary() async {
        let query = quoteQuery
        if !query.search.isEmpty {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
        }
        do {
            for try await library in database.quoteLibraryUpdates(matching: query.search, filter: query.filter) {
                quoteLibrary = library
            }
        } catch {
            if !Task.isCancelled { errorMessage = "Couldn't load your quotes. Quit the app and open it again." }
        }
    }

    // MARK: Search

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var searchQuery: SearchQuery {
        SearchQuery(text: searchText, scope: searchScope)
    }

    var searchScopeName: String {
        switch searchScope {
        case .everything: "Everything"
        case .item(let ref): tree.path(to: ref)
        }
    }

    // The search result that's currently open, so the list can highlight it.
    var activeResultId: UUID? {
        selectedQuoteId ?? selectedPageId
    }

    func openResult(id: UUID?) {
        guard let id else {
            sidebarSelection = nil
            return
        }
        if let page = searchResults.pages.first(where: { $0.id == id }) {
            openPage(id: page.id, sectionId: page.sectionId)
        } else if searchResults.quotes.contains(where: { $0.id == id }) {
            openQuote(id: id)
        }
    }

    func openPage(id: UUID, sectionId: UUID) {
        // So the page's place is showing in the sidebar once the search is cleared.
        if let notebookId = tree.notebookId(of: TreeItemRef(kind: .section, id: sectionId)) {
            openNotebookId = notebookId
        }
        isShowingNotebooks = false
        for ancestor in tree.ancestors(ofSection: sectionId) {
            expand(ancestor.id)
        }
        selectedSectionId = sectionId
        selectedPageId = id
        compactColumn = .detail
    }

    func openQuote(id: UUID) {
        sidebarSelection = .quotes
        selectedQuoteId = id
        compactColumn = .detail
    }

    // MARK: Quotes

    func beginQuote() {
        capture = QuoteCapture()
    }

    func createQuote(text: String, author: String, source: String, tags: String, sectionId: UUID?, pageId: UUID?) {
        attempt {
            try database.createQuote(
                text: text, author: author, source: source,
                tags: Quote.parseTags(tags), sectionId: sectionId, pageId: pageId
            )
        }
    }

    func updateQuote(_ quote: Quote) {
        attempt { try database.updateQuote(quote) }
    }

    func deleteQuote(id: UUID) {
        attempt {
            try database.deleteQuote(id: id)
            if selectedQuoteId == id { selectedQuoteId = nil }
        }
    }

    func showRandomQuote() {
        if let quote = quoteLibrary.randomQuote(excluding: selectedQuoteId) {
            selectedQuoteId = quote.id
            compactColumn = .detail
        }
    }

    func loadQuote(id: UUID) -> Quote? {
        try? database.quote(id: id)
    }

    func loadPage(id: UUID) -> Page? {
        try? database.page(id: id)
    }

    // For choosing a quote to place in a page. Doesn't touch the library screen's own search.
    func quotesToPick(matching search: String) -> [Quote] {
        (try? database.quotes(matching: search, limit: 100)) ?? []
    }

    // MARK: Notebook tree

    func openNotebook(id: UUID) {
        isShowingNotebooks = false
        guard id != openNotebookId else { return }
        openNotebookId = id
        // The library isn't part of any notebook, so it stays open if it's showing.
        guard sidebarSelection != .quotes else { return }
        #if os(macOS)
        // All the columns are on screen, so the book can reopen where it was left. On iPhone,
        // selecting a section would jump past the sections that were just asked for.
        let last = lastSections[id].flatMap { sectionId in
            tree.sections.first { $0.id == sectionId && $0.notebookId == id }
        }
        selectedSectionId = last?.id
        #else
        selectedSectionId = nil
        #endif
    }

    func toggleExpanded(_ id: UUID) {
        if expandedItems.contains(id) {
            expandedItems.remove(id)
        } else {
            expandedItems.insert(id)
        }
        saveExpanded()
    }

    private func expand(_ id: UUID) {
        expandedItems.insert(id)
        saveExpanded()
    }

    private func saveExpanded() {
        defaults.set(expandedItems.map(\.uuidString), forKey: Self.expandedKey)
    }

    func createNotebook(name: String) {
        attempt {
            let notebook = try database.createNotebook(name: name)
            openNotebook(id: notebook.id)
        }
    }

    func createGroup(name: String, in parent: TreeItemRef) {
        attempt {
            let group = try database.createGroup(name: name, in: parent)
            expand(parent.id)
            expand(group.id)
        }
    }

    func createSection(name: String, in parent: TreeItemRef) {
        attempt {
            let section = try database.createSection(name: name, in: parent)
            expand(parent.id)
            selectedSectionId = section.id
        }
    }

    func setColor(_ color: ItemColor?, of ref: TreeItemRef) {
        attempt { try database.setColor(color, of: ref) }
    }

    func rename(_ ref: TreeItemRef, to name: String) {
        attempt { try database.rename(ref, to: name) }
    }

    func delete(_ ref: TreeItemRef) {
        attempt { try database.delete(ref) }
    }

    // Called when a sidebar row is dragged. `destination` is the gap in the list as it was
    // before the row was picked up.
    func moveRow(from source: IndexSet, to destination: Int) {
        let rows = rows
        guard let openNotebookId, let index = source.first, destination != index, destination != index + 1 else { return }
        // The list has no row for the notebook itself, but the very top of the list is the same
        // place as just below an open notebook.
        let top = TreeRow(ref: TreeItemRef(kind: .notebook, id: openNotebookId), isExpanded: true)
        let above = destination > 0 ? rows[destination - 1] : top
        attempt { try database.move(rows[index].ref, below: above) }
    }

    func moveNotebook(from source: IndexSet, to destination: Int) {
        let notebooks = tree.notebooks.map { notebook in
            TreeRow(ref: TreeItemRef(kind: .notebook, id: notebook.id))
        }
        guard let index = source.first, destination != index, destination != index + 1 else { return }
        let above = destination > 0 ? notebooks[destination - 1] : nil
        attempt { try database.move(notebooks[index].ref, below: above) }
    }

    // Puts a group or section at the end of another notebook, with everything inside it.
    func move(_ ref: TreeItemRef, toNotebook notebookId: UUID) {
        let closed = TreeRow(ref: TreeItemRef(kind: .notebook, id: notebookId))
        attempt { try database.move(ref, below: closed) }
    }

    func addSampleData() {
        attempt { try database.addSampleData() }
    }

    // MARK: Pages

    func createPage() {
        guard let sectionId = selectedSectionId else { return }
        attempt {
            let page = try database.createPage(sectionId: sectionId)
            pages.append(page)
            selectedPageId = page.id
        }
    }

    func renamePage(id: UUID, title: String) {
        attempt { try database.renamePage(id: id, title: title) }
    }

    // The copy opens straight away, like a new page does.
    func duplicatePage(id: UUID) {
        // The page may be open with typing that's still waiting to be saved.
        openPageSavers[id]?()
        attempt {
            let copy = try database.duplicatePage(id: id)
            let index = pages.firstIndex { $0.id == id }.map { $0 + 1 } ?? pages.count
            pages.insert(copy, at: index)
            selectedPageId = copy.id
        }
    }

    func deletePage(id: UUID) {
        attempt { try database.deletePage(id: id) }
    }

    func movePage(id: UUID, toSection sectionId: UUID) {
        attempt { try database.movePage(id: id, toSection: sectionId) }
    }

    func reorderPages(from source: IndexSet, to destination: Int) {
        guard let sectionId = selectedSectionId, let first = source.first else { return }
        let id = pages[first].id
        attempt { try database.reorderPage(id: id, sectionId: sectionId, toPosition: destination) }
    }

    // MARK: Page contents

    // Returns nil if the page can't be read. The editor then stays closed, so that saving can
    // never replace a page it failed to understand.
    func loadDocument(pageId: UUID) -> PageDocument? {
        try? database.pageDocument(id: pageId)
    }

    func saveDocument(_ document: PageDocument, pageId: UUID) {
        attempt { try database.savePageDocument(document, id: pageId) }
    }

    func pageOpened(id: UUID, saver: @escaping () -> Void) {
        openPageSavers[id] = saver
    }

    func pageClosed(id: UUID) {
        openPageSavers[id] = nil
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            errorMessage = "Couldn't save that change. Try again."
        }
    }
}
