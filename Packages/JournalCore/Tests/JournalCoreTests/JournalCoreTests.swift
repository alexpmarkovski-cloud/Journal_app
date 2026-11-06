import Foundation
import GRDB
import Testing
@testable import JournalCore

private func ref(_ notebook: Notebook) -> TreeItemRef { TreeItemRef(kind: .notebook, id: notebook.id) }
private func ref(_ group: SectionGroup) -> TreeItemRef { TreeItemRef(kind: .group, id: group.id) }
private func ref(_ section: NoteSection) -> TreeItemRef { TreeItemRef(kind: .section, id: section.id) }

private func rowNames(_ db: AppDatabase, expanded: Set<UUID>) throws -> [String] {
    try db.tree().rows(expanded: expanded).map { String(repeating: "-", count: $0.depth) + $0.name }
}

@Suite struct TreeTests {
    @Test func rowsFollowNestingAndHideCollapsedItems() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "Personal")
        let group = try db.createGroup(name: "Journal", in: ref(notebook))
        try db.createSection(name: "November", in: ref(group))
        try db.createSection(name: "Ideas", in: ref(notebook))

        #expect(try rowNames(db, expanded: []) == ["Personal"])
        #expect(try rowNames(db, expanded: [notebook.id]) == ["Personal", "-Journal", "-Ideas"])
        #expect(try rowNames(db, expanded: [notebook.id, group.id]) == ["Personal", "-Journal", "--November", "-Ideas"])
    }

    @Test func sectionCannotHoldChildren() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "Personal")
        let section = try db.createSection(name: "Ideas", in: ref(notebook))
        #expect(throws: JournalError.self) {
            try db.createSection(name: "Nested", in: ref(section))
        }
    }

    @Test func renameChangesNameAndModifiedDate() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "Old")
        try db.rename(ref(notebook), to: "New")
        let renamed = try #require(try db.tree().notebooks.first)
        #expect(renamed.name == "New")
        #expect(renamed.modifiedAt >= notebook.modifiedAt.addingTimeInterval(-0.01))
    }

    @Test func deletingNotebookHidesEverythingInside() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "Personal")
        let keep = try db.createNotebook(name: "Keep")
        let group = try db.createGroup(name: "Journal", in: ref(notebook))
        let section = try db.createSection(name: "November", in: ref(group))
        try db.createPage(title: "Entry", sectionId: section.id)

        try db.delete(ref(notebook))

        let tree = try db.tree()
        #expect(tree.notebooks.map(\.id) == [keep.id])
        #expect(tree.groups.isEmpty)
        #expect(tree.sections.isEmpty)
        #expect(try db.pages(sectionId: section.id).isEmpty)
    }

    @Test func deletingGroupIncludesNestedGroupsButNotSiblings() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "Personal")
        let outer = try db.createGroup(name: "Outer", in: ref(notebook))
        let inner = try db.createGroup(name: "Inner", in: ref(outer))
        let nested = try db.createSection(name: "Nested", in: ref(inner))
        let sibling = try db.createSection(name: "Sibling", in: ref(notebook))
        try db.createPage(title: "Entry", sectionId: nested.id)

        try db.delete(ref(outer))

        let tree = try db.tree()
        #expect(tree.groups.isEmpty)
        #expect(tree.sections.map(\.id) == [sibling.id])
        #expect(try db.pages(sectionId: nested.id).isEmpty)
    }
}

@Suite struct MoveTests {
    private func row(_ item: TreeItemRef, open: Bool = false) -> TreeRow {
        TreeRow(ref: item, name: "", depth: 0, isExpanded: open)
    }

    @Test func notebookMovesToTheTop() throws {
        let db = try AppDatabase.inMemory()
        try db.createNotebook(name: "A")
        try db.createNotebook(name: "B")
        let c = try db.createNotebook(name: "C")
        try db.move(ref(c), below: nil)
        #expect(try db.tree().notebooks.map(\.name) == ["C", "A", "B"])
    }

    @Test func notebookBelowAnotherNotebooksSectionGoesAfterThatNotebook() throws {
        let db = try AppDatabase.inMemory()
        let a = try db.createNotebook(name: "A")
        try db.createNotebook(name: "B")
        let c = try db.createNotebook(name: "C")
        let section = try db.createSection(name: "S", in: ref(a))
        try db.move(ref(c), below: row(ref(section)))
        #expect(try db.tree().notebooks.map(\.name) == ["A", "C", "B"])
    }

    @Test func sectionCannotMoveAboveEveryNotebook() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let section = try db.createSection(name: "S", in: ref(notebook))
        try db.move(ref(section), below: nil)
        #expect(try rowNames(db, expanded: [notebook.id]) == ["N", "-S"])
    }

    @Test func sectionBelowSectionGoesRightAfterIt() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let first = try db.createSection(name: "First", in: ref(notebook))
        try db.createSection(name: "Second", in: ref(notebook))
        let third = try db.createSection(name: "Third", in: ref(notebook))
        try db.move(ref(third), below: row(ref(first)))
        #expect(try rowNames(db, expanded: [notebook.id]) == ["N", "-First", "-Third", "-Second"])
    }

    @Test func sectionBelowOpenGroupBecomesItsFirstChild() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let group = try db.createGroup(name: "G", in: ref(notebook))
        try db.createSection(name: "Inside", in: ref(group))
        let loose = try db.createSection(name: "Loose", in: ref(notebook))
        try db.move(ref(loose), below: row(ref(group), open: true))
        #expect(try rowNames(db, expanded: [notebook.id, group.id]) == ["N", "-G", "--Loose", "--Inside"])
    }

    @Test func sectionBelowClosedGroupStaysAtTheSameLevel() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let group = try db.createGroup(name: "G", in: ref(notebook))
        try db.createSection(name: "Other", in: ref(notebook))
        let loose = try db.createSection(name: "Loose", in: ref(notebook))
        try db.move(ref(loose), below: row(ref(group)))
        #expect(try rowNames(db, expanded: [notebook.id]) == ["N", "-G", "-Loose", "-Other"])
    }

    @Test func sectionBelowClosedNotebookGoesInsideAtTheEnd() throws {
        let db = try AppDatabase.inMemory()
        let a = try db.createNotebook(name: "A")
        let b = try db.createNotebook(name: "B")
        try db.createSection(name: "Existing", in: ref(b))
        let moving = try db.createSection(name: "Moving", in: ref(a))
        try db.move(ref(moving), below: row(ref(b)))
        #expect(try rowNames(db, expanded: [a.id, b.id]) == ["A", "B", "-Existing", "-Moving"])
    }

    @Test func sectionBelowOpenNotebookGoesFirst() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        try db.createSection(name: "First", in: ref(notebook))
        let last = try db.createSection(name: "Last", in: ref(notebook))
        try db.move(ref(last), below: row(ref(notebook), open: true))
        #expect(try rowNames(db, expanded: [notebook.id]) == ["N", "-Last", "-First"])
    }

    @Test func groupCannotMoveIntoItself() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let outer = try db.createGroup(name: "Outer", in: ref(notebook))
        let inner = try db.createGroup(name: "Inner", in: ref(outer))
        let insideInner = try db.createSection(name: "S", in: ref(inner))

        try db.move(ref(outer), below: row(ref(inner), open: true))
        try db.move(ref(outer), below: row(ref(insideInner)))

        #expect(try rowNames(db, expanded: [notebook.id, outer.id, inner.id]) == ["N", "-Outer", "--Inner", "---S"])
    }

    @Test func movingGroupToAnotherNotebookCarriesItsContents() throws {
        let db = try AppDatabase.inMemory()
        let from = try db.createNotebook(name: "From")
        let to = try db.createNotebook(name: "To")
        let group = try db.createGroup(name: "G", in: ref(from))
        let inner = try db.createGroup(name: "Inner", in: ref(group))
        try db.createSection(name: "S1", in: ref(group))
        try db.createSection(name: "S2", in: ref(inner))

        try db.move(ref(group), below: row(ref(to)))

        #expect(try rowNames(db, expanded: [from.id, to.id, group.id, inner.id]) == ["From", "To", "-G", "--Inner", "---S2", "--S1"])
        let tree = try db.tree()
        #expect(tree.groups.allSatisfy { $0.notebookId == to.id })
        #expect(tree.sections.allSatisfy { $0.notebookId == to.id })
    }

    @Test func moveOnlyChangesTheMovedItem() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let first = try db.createSection(name: "First", in: ref(notebook))
        let second = try db.createSection(name: "Second", in: ref(notebook))
        let third = try db.createSection(name: "Third", in: ref(notebook))

        try db.move(ref(third), below: row(ref(first)))

        let sections = try db.tree().sections
        #expect(sections.first { $0.id == first.id }?.sortOrder == first.sortOrder)
        #expect(sections.first { $0.id == second.id }?.sortOrder == second.sortOrder)
    }

    @Test func repeatedMovesIntoOneGapStayInOrder() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let first = try db.createSection(name: "First", in: ref(notebook))
        let a = try db.createSection(name: "A", in: ref(notebook))
        let b = try db.createSection(name: "B", in: ref(notebook))

        // Enough halvings to run out of decimal precision and force a renumber.
        for _ in 0..<60 {
            try db.move(ref(b), below: row(ref(first)))
            try db.move(ref(a), below: row(ref(first)))
        }

        let names = try db.tree().sections.map(\.name)
        #expect(names == ["First", "A", "B"])
        #expect(Set(try db.tree().sections.map(\.sortOrder)).count == 3)
    }

    @Test func sortOrderFindsTheGap() {
        #expect(AppDatabase.sortOrder(before: nil, after: nil) == 1)
        #expect(AppDatabase.sortOrder(before: nil, after: 3) == 2)
        #expect(AppDatabase.sortOrder(before: 3, after: nil) == 4)
        #expect(AppDatabase.sortOrder(before: 1, after: 2) == 1.5)
        #expect(AppDatabase.sortOrder(before: 1, after: 1.nextUp) == nil)
    }
}

// The sidebar shows one notebook at a time, so a row can have no row above it, and a section
// reaches another notebook through that notebook's closed row.
@Suite struct OneNotebookTests {
    private func names(_ db: AppDatabase, _ notebook: Notebook, expanded: Set<UUID> = []) throws -> [String] {
        try db.tree().rows(inNotebook: notebook.id, expanded: expanded).map {
            String(repeating: "-", count: $0.depth) + $0.name
        }
    }

    @Test func rowsCoverOnlyTheOneNotebook() throws {
        let db = try AppDatabase.inMemory()
        let journal = try db.createNotebook(name: "Journal")
        let year = try db.createGroup(name: "2026", in: ref(journal))
        try db.createSection(name: "August", in: ref(year))
        let other = try db.createNotebook(name: "Other")
        try db.createSection(name: "Therapy", in: ref(other))

        #expect(try names(db, journal, expanded: [year.id]) == ["2026", "-August"])
        #expect(try names(db, journal) == ["2026"])
        #expect(try names(db, other) == ["Therapy"])
    }

    @Test func sectionsListsNestedSectionsInOrder() throws {
        let db = try AppDatabase.inMemory()
        let journal = try db.createNotebook(name: "Journal")
        let year = try db.createGroup(name: "2026", in: ref(journal))
        try db.createSection(name: "August", in: ref(year))
        try db.createSection(name: "Ideas", in: ref(journal))

        let tree = try db.tree()
        #expect(tree.sections(inNotebook: journal.id).map(\.name) == ["August", "Ideas"])
    }

    @Test func aPathInsideANotebookLeavesItsNameOut() throws {
        let db = try AppDatabase.inMemory()
        let journal = try db.createNotebook(name: "Journal")
        let year = try db.createGroup(name: "2026", in: ref(journal))
        let august = try db.createSection(name: "August", in: ref(year))

        #expect(try db.tree().pathInsideNotebook(to: ref(august)) == "2026 › August")
    }

    @Test func aRowDraggedToTheVeryTopGoesFirstInItsNotebook() throws {
        let db = try AppDatabase.inMemory()
        let journal = try db.createNotebook(name: "Journal")
        try db.createSection(name: "First", in: ref(journal))
        let second = try db.createSection(name: "Second", in: ref(journal))

        let top = TreeRow(ref: ref(journal), name: "", depth: 0, isExpanded: true)
        try db.move(ref(second), below: top)

        #expect(try names(db, journal) == ["Second", "First"])
    }

    @Test func aSectionMovesToAnotherNotebookWithItsPages() throws {
        let db = try AppDatabase.inMemory()
        let journal = try db.createNotebook(name: "Journal")
        let august = try db.createSection(name: "August", in: ref(journal))
        let page = try db.createPage(title: "Rain", sectionId: august.id)
        let other = try db.createNotebook(name: "Other")
        try db.createSection(name: "Therapy", in: ref(other))

        let closed = TreeRow(ref: ref(other), name: "", depth: 0, isExpanded: false)
        try db.move(ref(august), below: closed)

        #expect(try names(db, journal).isEmpty)
        #expect(try names(db, other) == ["Therapy", "August"])
        #expect(try db.pages(sectionId: august.id).map(\.id) == [page.id])
    }

    @Test func aPageMovesToASectionInAnotherNotebook() throws {
        let db = try AppDatabase.inMemory()
        let journal = try db.createNotebook(name: "Journal")
        let august = try db.createSection(name: "August", in: ref(journal))
        let page = try db.createPage(title: "Rain", sectionId: august.id)
        let other = try db.createNotebook(name: "Other")
        let therapy = try db.createSection(name: "Therapy", in: ref(other))

        try db.movePage(id: page.id, toSection: therapy.id)

        #expect(try db.pages(sectionId: august.id).isEmpty)
        #expect(try db.pages(sectionId: therapy.id).map(\.id) == [page.id])
    }
}

@Suite struct ColorTests {
    @Test func anItemHasNoColorUntilOneIsChosen() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let section = try db.createSection(name: "S", in: ref(notebook))
        let tree = try db.tree()
        #expect(tree.color(of: ref(notebook)) == nil)
        #expect(tree.color(of: ref(section)) == nil)
    }

    @Test func notebooksAndSectionsKeepTheirColors() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let section = try db.createSection(name: "S", in: ref(notebook))

        try db.setColor(.purple, of: ref(notebook))
        try db.setColor(.teal, of: ref(section))

        let tree = try db.tree()
        #expect(tree.notebooks.first?.color == .purple)
        #expect(tree.sections.first?.color == .teal)
        #expect(tree.rows(inNotebook: notebook.id, expanded: []).first?.color == .teal)
        #expect(tree.rows(expanded: []).first?.color == .purple)
    }

    @Test func aColorCanBeTakenAway() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        try db.setColor(.red, of: ref(notebook))
        try db.setColor(nil, of: ref(notebook))
        #expect(try db.tree().notebooks.first?.color == nil)
    }

    @Test func aSectionKeepsItsColorWhenMovedToAnotherNotebook() throws {
        let db = try AppDatabase.inMemory()
        let first = try db.createNotebook(name: "First")
        let second = try db.createNotebook(name: "Second")
        let section = try db.createSection(name: "S", in: ref(first))
        try db.setColor(.green, of: ref(section))

        try db.move(ref(section), below: TreeRow(ref: ref(second)))

        let moved = try db.tree().sections.first
        #expect(moved?.notebookId == second.id)
        #expect(moved?.color == .green)
    }

    @Test func aGroupCantHaveAColor() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let group = try db.createGroup(name: "G", in: ref(notebook))
        #expect(throws: JournalError.self) { try db.setColor(.red, of: ref(group)) }
    }

    // A color added by a newer version of the app, arriving here through sync, must not stop
    // the notebook from loading.
    @Test func anUnknownColorIsTreatedAsNoColor() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        try db.writer.write { database in
            try database.execute(
                sql: "UPDATE notebook SET color_name = 'ultraviolet' WHERE id = ?",
                arguments: [notebook.id]
            )
        }
        let loaded = try db.tree().notebooks.first
        #expect(loaded?.name == "N")
        #expect(loaded?.color == nil)
    }

    // What happens on Alex's devices: notebooks and pages already exist when this version opens.
    @Test func upgradingKeepsEverythingAndAddsNoColors() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2: quotes and search")
        let notebookId = UUID()
        let sectionId = UUID()
        let pageId = UUID()
        let now = Date()
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO notebook (id, name, sort_order, created_at, modified_at) VALUES (?, 'Old book', 1, ?, ?)",
                arguments: [notebookId, now, now]
            )
            try db.execute(
                sql: "INSERT INTO section (id, notebook_id, name, sort_order, created_at, modified_at) VALUES (?, ?, 'Old section', 1, ?, ?)",
                arguments: [sectionId, notebookId, now, now]
            )
            try db.execute(
                sql: "INSERT INTO page (id, section_id, title, sort_order, created_at, modified_at) VALUES (?, ?, 'Old page', 1, ?, ?)",
                arguments: [pageId, sectionId, now, now]
            )
        }

        let db = try AppDatabase(queue)

        let tree = try db.tree()
        #expect(tree.notebooks.map(\.name) == ["Old book"])
        #expect(tree.sections.map(\.name) == ["Old section"])
        #expect(tree.notebooks.first?.color == nil)
        #expect(tree.sections.first?.color == nil)
        #expect(try db.pages(sectionId: sectionId).map(\.title) == ["Old page"])
    }
}

@Suite struct PageTests {
    private func makeSection(_ db: AppDatabase) throws -> NoteSection {
        let notebook = try db.createNotebook(name: "N")
        return try db.createSection(name: "S", in: ref(notebook))
    }

    @Test func createRenameDelete() throws {
        let db = try AppDatabase.inMemory()
        let section = try makeSection(db)
        let page = try db.createPage(title: "Draft", sectionId: section.id)
        try db.renamePage(id: page.id, title: "Final")
        #expect(try db.pages(sectionId: section.id).map(\.title) == ["Final"])
        try db.deletePage(id: page.id)
        #expect(try db.pages(sectionId: section.id).isEmpty)
    }

    @Test(arguments: [(0, ["C", "A", "B"]), (1, ["A", "C", "B"]), (3, ["A", "B", "C"])])
    func reorderLastPage(position: Int, expected: [String]) throws {
        let db = try AppDatabase.inMemory()
        let section = try makeSection(db)
        for title in ["A", "B"] {
            try db.createPage(title: title, sectionId: section.id)
        }
        let c = try db.createPage(title: "C", sectionId: section.id)
        try db.reorderPage(id: c.id, sectionId: section.id, toPosition: position)
        #expect(try db.pages(sectionId: section.id).map(\.title) == expected)
    }

    @Test func reorderFirstPageDownward() throws {
        let db = try AppDatabase.inMemory()
        let section = try makeSection(db)
        let a = try db.createPage(title: "A", sectionId: section.id)
        for title in ["B", "C"] {
            try db.createPage(title: title, sectionId: section.id)
        }
        try db.reorderPage(id: a.id, sectionId: section.id, toPosition: 2)
        #expect(try db.pages(sectionId: section.id).map(\.title) == ["B", "A", "C"])
    }

    @Test func movePageToAnotherSection() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let from = try db.createSection(name: "From", in: ref(notebook))
        let to = try db.createSection(name: "To", in: ref(notebook))
        try db.createPage(title: "Existing", sectionId: to.id)
        let page = try db.createPage(title: "Moved", sectionId: from.id)

        try db.movePage(id: page.id, toSection: to.id)

        #expect(try db.pages(sectionId: from.id).isEmpty)
        #expect(try db.pages(sectionId: to.id).map(\.title) == ["Existing", "Moved"])
    }

    @Test func duplicateGoesRightBelowTheOriginal() throws {
        let db = try AppDatabase.inMemory()
        let section = try makeSection(db)
        let a = try db.createPage(title: "A", sectionId: section.id)
        try db.createPage(title: "B", sectionId: section.id)

        try db.duplicatePage(id: a.id)

        #expect(try db.pages(sectionId: section.id).map(\.title) == ["A", "A copy", "B"])
    }

    @Test func duplicateCopiesTheBodyAndKeepsTheDate() throws {
        let db = try AppDatabase.inMemory()
        let section = try makeSection(db)
        let original = try db.createPage(title: "A", sectionId: section.id)
        let document = PageDocument(blocks: [Block(runs: [TextRun("Rain on the roof")])])
        try db.savePageDocument(document, id: original.id)

        let copy = try db.duplicatePage(id: original.id)

        #expect(copy.id != original.id)
        // Compared with the stored date, because the database keeps dates to the millisecond.
        #expect(copy.createdAt == (try db.page(id: original.id))?.createdAt)
        #expect(try db.pageDocument(id: copy.id) == document)
    }

    @Test func aDuplicateIsIndependentOfTheOriginal() throws {
        let db = try AppDatabase.inMemory()
        let section = try makeSection(db)
        let original = try db.createPage(title: "A", sectionId: section.id)
        let document = PageDocument(blocks: [Block(runs: [TextRun("First")])])
        try db.savePageDocument(document, id: original.id)
        let copy = try db.duplicatePage(id: original.id)

        try db.savePageDocument(PageDocument(blocks: [Block(runs: [TextRun("Changed")])]), id: copy.id)
        try db.deletePage(id: copy.id)

        #expect(try db.pageDocument(id: original.id) == document)
        #expect(try db.pages(sectionId: section.id).map(\.id) == [original.id])
    }

    @Test func aDuplicateCanBeFound() throws {
        let db = try AppDatabase.inMemory()
        let section = try makeSection(db)
        let original = try db.createPage(title: "A", sectionId: section.id)
        try db.savePageDocument(PageDocument(blocks: [Block(runs: [TextRun("Rain")])]), id: original.id)

        let copy = try db.duplicatePage(id: original.id)

        #expect(Set(try db.search("rain").pages.map(\.id)) == [original.id, copy.id])
    }

    @Test func untitledStaysUntitledWhenDuplicated() throws {
        let db = try AppDatabase.inMemory()
        let section = try makeSection(db)
        let page = try db.createPage(sectionId: section.id)
        #expect(try db.duplicatePage(id: page.id).title == "")
    }

    @Test func aDeletedPageCantBeDuplicated() throws {
        let db = try AppDatabase.inMemory()
        let section = try makeSection(db)
        let page = try db.createPage(title: "A", sectionId: section.id)
        try db.deletePage(id: page.id)
        #expect(throws: JournalError.self) { try db.duplicatePage(id: page.id) }
    }

    @Test func updatesFireWhenPagesChange() async throws {
        let db = try AppDatabase.inMemory()
        let section = try makeSection(db)
        var updates = db.pageUpdates(sectionId: section.id).makeAsyncIterator()
        #expect(try await updates.next()?.isEmpty == true)
        try db.createPage(title: "New", sectionId: section.id)
        #expect(try await updates.next()?.map(\.title) == ["New"])
    }
}

@Suite struct PageDocumentTests {
    private func sampleDocument() -> PageDocument {
        var styled = TextStyle()
        styled.bold = true
        styled.slant = .backwards
        styled.strikethrough = true
        styled.underline = true
        styled.font = "Georgia"
        styled.size = 22
        styled.link = "https://example.com"
        return PageDocument(blocks: [
            Block(kind: .heading1, runs: [TextRun("Title")]),
            Block(runs: [TextRun("plain "), TextRun("styled", style: styled)]),
            Block(kind: .bullet, runs: [TextRun("nested")], level: 2),
            Block(kind: .checklist, runs: [TextRun("done")], isChecked: true),
            Block(kind: .code, runs: [TextRun("let x = 1")]),
            Block(kind: .divider),
            Block(kind: .table, table: TableData(rows: [["Company", "Status"], ["Acme", "Applied"]])),
        ])
    }

    @Test func jsonRoundTripKeepsEverything() throws {
        let document = sampleDocument()
        #expect(try PageDocument.decoded(from: document.encoded()) == document)
    }

    @Test func defaultsAreLeftOutOfTheJson() throws {
        let document = PageDocument(blocks: [Block(runs: [TextRun("hi")])])
        let json = try #require(String(data: document.encoded(), encoding: .utf8))
        #expect(json == #"{"blocks":[{"runs":[{"text":"hi"}]}],"version":3}"#)
    }

    @Test func pageFromANewerAppIsRefused() throws {
        let data = Data(#"{"blocks":[],"version":999}"#.utf8)
        #expect(throws: JournalError.self) {
            try PageDocument.decoded(from: data)
        }
    }

    @Test func plainTextIncludesTableCells() {
        #expect(sampleDocument().plainText.contains("Acme Applied"))
    }

    @Test func savedBodyComesBackAndUpdatesModifiedDate() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let section = try db.createSection(name: "S", in: ref(notebook))
        let page = try db.createPage(title: "P", sectionId: section.id)
        #expect(try db.pageDocument(id: page.id) == PageDocument())

        let document = sampleDocument()
        try db.savePageDocument(document, id: page.id)

        #expect(try db.pageDocument(id: page.id) == document)
        let saved = try #require(try db.pages(sectionId: section.id).first)
        #expect(saved.modifiedAt >= page.modifiedAt.addingTimeInterval(-0.01))
    }

    @Test func damagedBodyThrowsInsteadOfLookingEmpty() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "N")
        let section = try db.createSection(name: "S", in: ref(notebook))
        let page = try db.createPage(sectionId: section.id)
        try db.writer.write { database in
            try database.execute(
                sql: "UPDATE page SET body = ? WHERE id = ?",
                arguments: [Data("not json".utf8), page.id]
            )
        }
        #expect(throws: (any Error).self) {
            try db.pageDocument(id: page.id)
        }
    }
}

@Suite struct SampleDataTests {
    @Test func sampleDataBuildsATree() throws {
        let db = try AppDatabase.inMemory()
        try db.addSampleData()
        let tree = try db.tree()
        #expect(tree.notebooks.map(\.name) == ["Personal", "Food", "Learning"])
        #expect(tree.groups.count == 1)
        #expect(tree.sections.count == 6)
    }
}

@Suite("Code inside list items")
struct ListItemTextKindTests {
    @Test func aListItemKeepsItsCodeThroughSaving() throws {
        let document = PageDocument(blocks: [Block(kind: .numbered, runs: [TextRun("let x = 1")], textKind: .code)])
        let reloaded = try PageDocument.decoded(from: document.encoded())
        #expect(reloaded == document)
        #expect(reloaded.blocks[0].contentKind == .code)
    }

    @Test func aDashListKeepsItsDashesThroughSaving() throws {
        let document = PageDocument(blocks: [Block(kind: .dash, runs: [TextRun("item")], level: 1, textKind: .code)])
        let reloaded = try PageDocument.decoded(from: document.encoded())
        #expect(reloaded == document)
        #expect(BlockKind.dash.isList)
    }

    // Pages saved by the build from before dash lists.
    @Test func versionTwoPagesStillOpen() throws {
        let data = Data(#"{"blocks":[{"kind":"numbered","runs":[{"text":"hi"}],"textKind":"code"}],"version":2}"#.utf8)
        let document = try PageDocument.decoded(from: data)
        #expect(document.blocks == [Block(kind: .numbered, runs: [TextRun("hi")], textKind: .code)])
    }

    // What happens on Alex's devices: every page saved so far has version 1 and no textKind.
    @Test func pagesSavedBeforeThisStillOpen() throws {
        let data = Data(#"{"blocks":[{"kind":"numbered","runs":[{"text":"hi"}]}],"version":1}"#.utf8)
        let document = try PageDocument.decoded(from: data)
        #expect(document.blocks == [Block(kind: .numbered, runs: [TextRun("hi")])])
        #expect(document.blocks[0].contentKind == .paragraph)
    }
}
