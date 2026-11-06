// The first column: the open notebook, the search box, the quote library, and that notebook's
// sections. Its name opens the list of notebooks. While there's anything in the search box, its
// results take the place of the rest.

import JournalCore
import SwiftUI

// What the name prompt is currently asking for.
private enum NamePrompt {
    case newNotebook
    case newGroup(parent: TreeItemRef)
    case newSection(parent: TreeItemRef)
    case rename(TreeItemRef)

    var title: String {
        switch self {
        case .newNotebook: "New notebook"
        case .newGroup: "New section group"
        case .newSection: "New section"
        case .rename: "Rename"
        }
    }
}

struct SidebarView: View {
    @Bindable var model: JournalModel

    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var pendingDelete: TreeItemRef?
    @State private var isChoosingScope = false
    @State private var coloring: TreeItemRef?
    @State private var isShowingSettings = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !model.tree.isEmpty {
                notebookHeader
            }

            SearchField(
                prompt: model.searchScope == .everything ? "Search everything" : "Search",
                text: $model.searchText,
                shortcut: KeyboardShortcut("f", modifiers: [.command, .shift]),
                focus: $isSearchFocused
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if model.isSearching || model.searchScope != .everything {
                scopeRow
            }

            if model.isSearching {
                SearchResultsView(model: model)
            } else if model.isShowingNotebooks {
                notebookList
            } else {
                sectionList
            }
        }
        .navigationTitle(model.openNotebook?.name ?? "Journal")
        #if os(iOS)
        // The notebook's name at the top of the column takes the place of the usual title.
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Menu("New", systemImage: "plus") {
                    Button("New quote", systemImage: "text.quote", action: model.beginQuote)
                        .keyboardShortcut("k", modifiers: [.command, .shift])
                    Button("New notebook", systemImage: "book.closed") { ask(.newNotebook) }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                #if os(macOS)
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                #else
                Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                #endif
            }
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        #endif
        .sheet(isPresented: isChoosingColor) {
            if let coloring {
                ItemColorPicker(
                    name: model.tree.name(of: coloring) ?? "",
                    current: model.tree.color(of: coloring)
                ) { model.setColor($0, of: coloring) }
            }
        }
        .sheet(isPresented: $isChoosingScope) {
            SearchScopePicker(model: model) { isSearchFocused = true }
        }
        .alert(prompt?.title ?? "", isPresented: isShowingPrompt) {
            TextField("Name", text: $promptText)
            Button("Save", action: submitPrompt)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: isShowingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { model.delete(pendingDelete) }
            }
        } message: {
            Text("Everything inside it is deleted too.")
        }
    }

    // MARK: Notebooks

    private var notebookHeader: some View {
        Button {
            model.isShowingNotebooks.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(model.isShowingNotebooks ? Color.accentColor : model.openNotebook?.color?.shade ?? .accentColor)
                Text(model.isShowingNotebooks ? "Notebooks" : model.openNotebook?.name ?? "Notebooks")
                    #if os(iOS)
                    .font(.title2.weight(.bold))
                    #else
                    .font(.headline)
                    #endif
                    .lineLimit(1)
                Image(systemName: model.isShowingNotebooks ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows your notebooks")
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private var notebookList: some View {
        List {
            ForEach(model.tree.notebooks) { notebook in
                Button {
                    model.openNotebook(id: notebook.id)
                } label: {
                    HStack(spacing: 8) {
                        ItemIcon(kind: .notebook, color: notebook.color)
                        Text(notebook.name)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if notebook.id == model.openNotebookId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Open")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { menu(forNotebook: notebook) }
                .themedRow()
            }
            .onMove(perform: model.moveNotebook)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomBar {
                Button("Add notebook", systemImage: "plus") { ask(.newNotebook) }
                    .bottomBarButtonStyle()
            }
        }
    }

    @ViewBuilder
    private func menu(forNotebook notebook: Notebook) -> some View {
        let ref = TreeItemRef(kind: .notebook, id: notebook.id)
        Button("Search in here", systemImage: "magnifyingglass") {
            model.searchScope = .item(ref)
            isSearchFocused = true
        }
        Divider()
        Button("Color", systemImage: "paintpalette") { coloring = ref }
        Button("Rename", systemImage: "pencil") { ask(.rename(ref)) }
        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = ref }
    }

    private var sectionList: some View {
        List(selection: $model.sidebarSelection) {
            Section {
                Label("Quotes", systemImage: "text.quote")
                    .tag(SidebarItem.quotes)
                    .themedRow()
            }
            if model.hasLoadedTree && model.tree.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
                    .themedRow()
            } else {
                Section {
                    ForEach(model.rows) { row in
                        rowView(row)
                            .themedRow()
                    }
                    .onMove(perform: model.moveRow)
                    if model.hasLoadedTree && model.rows.isEmpty {
                        Text("No sections yet")
                            .foregroundStyle(.secondary)
                            .themedRow()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notebookId = model.openNotebookId {
                BottomBar {
                    let notebook = TreeItemRef(kind: .notebook, id: notebookId)
                    Menu("Add section", systemImage: "plus") {
                        Button("New section", systemImage: "doc.badge.plus") { ask(.newSection(parent: notebook)) }
                        Button("New section group", systemImage: "folder.badge.plus") { ask(.newGroup(parent: notebook)) }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
    }

    // MARK: Search scope

    // Says where the search is looking. The name starts cut off rather than ending cut off,
    // because the end is the part that tells "2026 › August" from "2025 › August".
    private var scopeRow: some View {
        HStack(spacing: 6) {
            Button { isChoosingScope = true } label: {
                HStack(spacing: 4) {
                    if model.searchScope == .everything {
                        Text("Searching everything")
                    } else {
                        Text("In")
                        Text(model.searchScopeName)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .contentShape(Rectangle())
            }
            .accessibilityHint("Choose where to search")
            Spacer(minLength: 0)
            if model.searchScope != .everything {
                Button("Search everything", systemImage: "xmark") {
                    model.searchScope = .everything
                }
                .labelStyle(.iconOnly)
                .font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Start your first notebook", systemImage: "book.closed")
        } description: {
            Text("Notebooks hold section groups, sections and pages.")
        } actions: {
            Button("Create notebook") { ask(.newNotebook) }
            Button("Add sample notebooks") { model.addSampleData() }
        }
    }

    @ViewBuilder
    private func rowView(_ row: TreeRow) -> some View {
        let label = rowLabel(row)
            .padding(.leading, CGFloat(row.depth) * 14)
            .contextMenu { menu(for: row) }

        // Only sections can be selected. Groups open and close instead.
        if row.ref.kind == .section {
            label.tag(SidebarItem.section(row.id))
        } else {
            Button {
                model.toggleExpanded(row.id)
            } label: {
                label
            }
            .buttonStyle(.plain)
        }
    }

    private func rowLabel(_ row: TreeRow) -> some View {
        HStack(spacing: 6) {
            if row.ref.kind == .section {
                // Keeps section names lined up with the names of rows that have an arrow.
                Color.clear.frame(width: 12, height: 1)
            } else {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            ItemIcon(kind: row.ref.kind, color: row.color)
            Text(row.name)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func menu(for row: TreeRow) -> some View {
        Button("Search in here", systemImage: "magnifyingglass") {
            model.searchScope = .item(row.ref)
            isSearchFocused = true
        }
        Divider()
        if row.ref.kind != .section {
            Button("New section", systemImage: "doc.badge.plus") { ask(.newSection(parent: row.ref)) }
            Button("New section group", systemImage: "folder.badge.plus") { ask(.newGroup(parent: row.ref)) }
            Divider()
        }
        if row.ref.kind == .section {
            Button("Color", systemImage: "paintpalette") { coloring = row.ref }
        }
        Menu("Move to notebook", systemImage: "book.closed") {
            ForEach(model.tree.notebooks.filter { $0.id != model.openNotebookId }) { notebook in
                Button(notebook.name) { model.move(row.ref, toNotebook: notebook.id) }
            }
        }
        Button("Rename", systemImage: "pencil") { ask(.rename(row.ref)) }
        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = row.ref }
    }

    // MARK: Prompts

    private func ask(_ newPrompt: NamePrompt) {
        if case .rename(let ref) = newPrompt {
            promptText = model.tree.name(of: ref) ?? ""
        } else {
            promptText = ""
        }
        prompt = newPrompt
    }

    private func submitPrompt() {
        let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let prompt else { return }
        switch prompt {
        case .newNotebook: model.createNotebook(name: name)
        case .newGroup(let parent): model.createGroup(name: name, in: parent)
        case .newSection(let parent): model.createSection(name: name, in: parent)
        case .rename(let ref): model.rename(ref, to: name)
        }
    }

    private var isShowingPrompt: Binding<Bool> {
        Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    }

    private var isChoosingColor: Binding<Bool> {
        Binding(get: { coloring != nil }, set: { if !$0 { coloring = nil } })
    }

    private var isShowingDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteTitle: String {
        guard let pendingDelete, let name = model.tree.name(of: pendingDelete) else { return "Delete?" }
        return "Delete \"\(name)\"?"
    }
}
