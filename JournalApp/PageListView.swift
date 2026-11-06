// The second column: the pages in the selected section.

import JournalCore
import SwiftUI

struct PageListView: View {
    @Bindable var model: JournalModel

    var body: some View {
        Group {
            if let section = model.selectedSection {
                pageList
                    .navigationTitle(section.name)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        BottomBar {
                            Button("Add page", systemImage: "plus") { model.createPage() }
                                .bottomBarButtonStyle()
                        }
                    }
            } else {
                ContentUnavailableView("Choose a section", systemImage: "doc.text")
            }
        }
    }

    @ViewBuilder
    private var pageList: some View {
        if model.pages.isEmpty {
            ContentUnavailableView("Write your first page", systemImage: "square.and.pencil")
        } else {
            List(selection: $model.selectedPageId) {
                ForEach(model.pages) { page in
                    PageRow(page: page)
                        .tag(page.id)
                        .themedRow(.page)
                        .contextMenu { menu(for: page) }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.deletePage(id: page.id)
                            }
                        }
                }
                .onMove(perform: model.reorderPages)
            }
        }
    }

    @ViewBuilder
    private func menu(for page: Page) -> some View {
        Button("Duplicate", systemImage: "plus.square.on.square") {
            model.duplicatePage(id: page.id)
        }
        // Pages can go anywhere, so every notebook's sections are listed, not only this one's.
        Menu("Move to", systemImage: "folder") {
            ForEach(model.tree.notebooks) { notebook in
                let sections = model.tree.sections(inNotebook: notebook.id).filter { $0.id != page.sectionId }
                if !sections.isEmpty {
                    Menu(notebook.name) {
                        ForEach(sections) { section in
                            Button(model.tree.pathInsideNotebook(to: section.ref)) {
                                model.movePage(id: page.id, toSection: section.id)
                            }
                        }
                    }
                }
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            model.deletePage(id: page.id)
        }
    }
}

private struct PageRow: View {
    let page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(page.title.isEmpty ? "Untitled" : page.title)
                .lineLimit(1)
            Text(page.modifiedAt, format: .dateTime.month(.abbreviated).day())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
