// Tests for quotes and full-text search.

import Foundation
import GRDB
import Testing
@testable import JournalCore

private func document(_ text: String) -> PageDocument {
    PageDocument(blocks: [Block(runs: [TextRun(text)])])
}

private func emptySection(_ db: AppDatabase) throws -> NoteSection {
    let notebook = try db.createNotebook(name: "Notes")
    return try db.createSection(name: "General", in: TreeItemRef(kind: .notebook, id: notebook.id))
}

private func text(_ parts: [SnippetPart]) -> String {
    parts.map(\.text).joined()
}

@Suite struct PageSearchTests {
    @Test func findsPagesByTitleAndTextAndForgetsOldWords() throws {
        let db = try AppDatabase.inMemory()
        let page = try db.createPage(title: "Tomato soup", sectionId: try emptySection(db).id)
        try db.savePageDocument(document("Roast the garlic"), id: page.id)

        #expect(try db.search("tomato").pages.map(\.id) == [page.id])
        #expect(try db.search("garlic").pages.map(\.id) == [page.id])

        try db.renamePage(id: page.id, title: "Lentil stew")
        try db.savePageDocument(document("Toast the cumin"), id: page.id)

        #expect(try db.search("tomato").isEmpty)
        #expect(try db.search("garlic").isEmpty)
        #expect(try db.search("lentil").pages.map(\.id) == [page.id])
        #expect(try db.search("cumin").pages.map(\.id) == [page.id])
    }

    @Test func aDeletedPageIsNotFound() throws {
        let db = try AppDatabase.inMemory()
        let page = try db.createPage(title: "Tomato soup", sectionId: try emptySection(db).id)
        try db.deletePage(id: page.id)
        #expect(try db.search("tomato").isEmpty)
    }

    @Test func deletingANotebookRemovesItsPagesFromSearch() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "Food")
        let notebookRef = TreeItemRef(kind: .notebook, id: notebook.id)
        let group = try db.createGroup(name: "Meals", in: notebookRef)
        let section = try db.createSection(name: "Soups", in: TreeItemRef(kind: .group, id: group.id))
        try db.createPage(title: "Tomato soup", sectionId: section.id)

        try db.delete(notebookRef)

        #expect(try db.search("tomato").isEmpty)
    }

    @Test func aMovedPageReportsItsNewSection() throws {
        let db = try AppDatabase.inMemory()
        let first = try emptySection(db)
        let second = try db.createSection(name: "Other", in: TreeItemRef(kind: .notebook, id: first.notebookId))
        let page = try db.createPage(title: "Tomato soup", sectionId: first.id)

        try db.movePage(id: page.id, toSection: second.id)

        #expect(try db.search("tomato").pages.first?.sectionId == second.id)
    }

    @Test func titleMatchesRankAboveTextMatches() throws {
        let db = try AppDatabase.inMemory()
        let section = try emptySection(db)
        let mentions = try db.createPage(title: "Dinner", sectionId: section.id)
        try db.savePageDocument(document("We had soup tonight and it was fine"), id: mentions.id)
        let titled = try db.createPage(title: "Soup", sectionId: section.id)

        #expect(try db.search("soup").pages.map(\.id) == [titled.id, mentions.id])
    }

    @Test func tableCellsAreSearchable() throws {
        let db = try AppDatabase.inMemory()
        let page = try db.createPage(title: "Jobs", sectionId: try emptySection(db).id)
        let table = TableData(rows: [["Company", "Status"], ["Acme", "Interview"]])
        try db.savePageDocument(PageDocument(blocks: [Block(kind: .table, table: table)]), id: page.id)

        #expect(try db.search("interview").pages.map(\.id) == [page.id])
    }

    @Test func matchingWordsAreMarked() throws {
        let db = try AppDatabase.inMemory()
        let page = try db.createPage(title: "Soup notes", sectionId: try emptySection(db).id)
        try db.savePageDocument(document("Good soup takes time"), id: page.id)

        let result = try #require(try db.search("soup").pages.first)
        #expect(result.title == [
            SnippetPart(text: "Soup", isMatch: true),
            SnippetPart(text: " notes", isMatch: false),
        ])
        #expect(result.snippet == [
            SnippetPart(text: "Good ", isMatch: false),
            SnippetPart(text: "soup", isMatch: true),
            SnippetPart(text: " takes time", isMatch: false),
        ])
    }
}

@Suite struct SectionPathTests {
    @Test func writesOutWhereASectionLives() throws {
        let db = try AppDatabase.inMemory()
        let notebook = try db.createNotebook(name: "Personal")
        let outer = try db.createGroup(name: "Journal", in: TreeItemRef(kind: .notebook, id: notebook.id))
        let inner = try db.createGroup(name: "2026", in: TreeItemRef(kind: .group, id: outer.id))
        let section = try db.createSection(name: "November", in: TreeItemRef(kind: .group, id: inner.id))

        let tree = try db.tree()
        #expect(tree.path(toSection: section.id) == "Personal › Journal › 2026 › November")
        #expect(tree.ancestors(ofSection: section.id).map(\.id) == [notebook.id, outer.id, inner.id])
        #expect(tree.path(toSection: UUID()) == "")
    }
}

@Suite struct SearchScopeTests {
    private struct Journal {
        let db: AppDatabase
        let personal: Notebook
        let year: SectionGroup
        let august: NoteSection
        let september: NoteSection
        let august2025: NoteSection
        let food: NoteSection
    }

    // Personal > 2026 > Summer > August, Personal > 2026 > September,
    // Personal > 2025 > August, and Food > Recipes. Every section has a page about rain.
    private func makeJournal() throws -> Journal {
        let db = try AppDatabase.inMemory()
        let personal = try db.createNotebook(name: "Personal")
        let personalRef = TreeItemRef(kind: .notebook, id: personal.id)
        let year = try db.createGroup(name: "2026", in: personalRef)
        let summer = try db.createGroup(name: "Summer", in: TreeItemRef(kind: .group, id: year.id))
        let august = try db.createSection(name: "August", in: TreeItemRef(kind: .group, id: summer.id))
        let september = try db.createSection(name: "September", in: TreeItemRef(kind: .group, id: year.id))
        let lastYear = try db.createGroup(name: "2025", in: personalRef)
        let august2025 = try db.createSection(name: "August", in: TreeItemRef(kind: .group, id: lastYear.id))
        let foodBook = try db.createNotebook(name: "Food")
        let food = try db.createSection(name: "Recipes", in: TreeItemRef(kind: .notebook, id: foodBook.id))
        for section in [august, september, august2025, food] {
            try db.createPage(title: "Rain", sectionId: section.id)
        }
        return Journal(db: db, personal: personal, year: year, august: august, september: september, august2025: august2025, food: food)
    }

    private func sectionsFound(_ journal: Journal, _ ref: TreeItemRef) throws -> Set<UUID> {
        Set(try journal.db.search("rain", in: .item(ref)).pages.map(\.sectionId))
    }

    @Test func everythingCoversTheWholeJournal() throws {
        let journal = try makeJournal()
        #expect(try journal.db.search("rain").pages.count == 4)
        #expect(try journal.db.search("rain", in: .everything).pages.count == 4)
    }

    @Test func aSectionCoversOnlyItself() throws {
        let journal = try makeJournal()
        let found = try sectionsFound(journal, TreeItemRef(kind: .section, id: journal.august.id))
        #expect(found == [journal.august.id])
    }

    @Test func aGroupIncludesGroupsNestedInsideIt() throws {
        let journal = try makeJournal()
        let found = try sectionsFound(journal, TreeItemRef(kind: .group, id: journal.year.id))
        #expect(found == [journal.august.id, journal.september.id])
    }

    @Test func aNotebookCoversAllItsGroupsAndNothingElse() throws {
        let journal = try makeJournal()
        let found = try sectionsFound(journal, TreeItemRef(kind: .notebook, id: journal.personal.id))
        #expect(found == [journal.august.id, journal.september.id, journal.august2025.id])
    }

    @Test func quotesCountOnlyIfFiledInsideTheScope() throws {
        let journal = try makeJournal()
        let inside = try journal.db.createQuote(text: "Rain on the roof", sectionId: journal.august.id)
        try journal.db.createQuote(text: "Rain in the valley", sectionId: journal.food.id)
        try journal.db.createQuote(text: "Rain with no home")

        let results = try journal.db.search("rain", in: .item(TreeItemRef(kind: .group, id: journal.year.id)))
        #expect(results.quotes.map(\.id) == [inside.id])
        #expect(try journal.db.search("rain").quotes.count == 3)
    }

    @Test func aPageMovedOutOfTheScopeStopsMatching() throws {
        let journal = try makeJournal()
        let august = TreeItemRef(kind: .section, id: journal.august.id)
        let page = try #require(try journal.db.search("rain", in: .item(august)).pages.first)

        try journal.db.movePage(id: page.id, toSection: journal.food.id)

        #expect(try journal.db.search("rain", in: .item(august)).isEmpty)
    }

    @Test func aScopeWithNoSectionsFindsNothing() throws {
        let journal = try makeJournal()
        let empty = try journal.db.createGroup(name: "Empty", in: TreeItemRef(kind: .notebook, id: journal.personal.id))
        #expect(try journal.db.search("rain", in: .item(TreeItemRef(kind: .group, id: empty.id))).isEmpty)
    }

    @Test func aDeletedScopeFindsNothing() throws {
        let journal = try makeJournal()
        let august = TreeItemRef(kind: .section, id: journal.august.id)
        try journal.db.delete(august)
        #expect(try journal.db.search("rain", in: .item(august)).isEmpty)
    }

    @Test func updatesStayWithinTheScope() async throws {
        let journal = try makeJournal()
        let august = TreeItemRef(kind: .section, id: journal.august.id)
        var iterator = journal.db.searchUpdates("orchard", in: .item(august)).makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)

        // Outside the scope first: this must not produce a result. The next one is the inside page.
        try journal.db.createPage(title: "Orchard", sectionId: journal.food.id)
        let inside = try journal.db.createPage(title: "Orchard", sectionId: journal.august.id)

        #expect(try await iterator.next()?.pages.map(\.id) == [inside.id])
    }

    @Test func pathsAndAncestorsWorkForEveryKindOfItem() throws {
        let journal = try makeJournal()
        let tree = try journal.db.tree()
        #expect(tree.path(to: TreeItemRef(kind: .notebook, id: journal.personal.id)) == "Personal")
        #expect(tree.path(to: TreeItemRef(kind: .group, id: journal.year.id)) == "Personal › 2026")
        #expect(tree.path(to: TreeItemRef(kind: .section, id: journal.august.id)) == "Personal › 2026 › Summer › August")
        #expect(tree.allRows.count == 9)
    }
}

@Suite struct SearchQueryTests {
    @Test func halfTypedWordsMatch() throws {
        let db = try AppDatabase.inMemory()
        let quote = try db.createQuote(text: "Humility is a quiet strength")
        for typed in ["h", "hu", "hum", "humil", "HUMILITY"] {
            #expect(try db.search(typed).quotes.map(\.id) == [quote.id], "\(typed)")
        }
        #expect(try db.search("humbug").isEmpty)
    }

    @Test func wordsCanMatchInAnyOrderAndAnyField() throws {
        let db = try AppDatabase.inMemory()
        let quote = try db.createQuote(text: "Plant the tree", author: "Mira Holloway")
        try db.createQuote(text: "Plant the garden", author: "Tomas Reyna")

        #expect(try db.search("holloway plant").quotes.map(\.id) == [quote.id])
    }

    @Test func accentsAndCapitalsDoNotMatter() throws {
        let db = try AppDatabase.inMemory()
        let quote = try db.createQuote(text: "Meet me at the Café")
        #expect(try db.search("cafe").quotes.map(\.id) == [quote.id])
        #expect(try db.search("CAFÉ").quotes.map(\.id) == [quote.id])
    }

    @Test func apostrophesWorkBothWays() throws {
        let db = try AppDatabase.inMemory()
        let quote = try db.createQuote(text: "Don't look back")
        #expect(try db.search("don't").quotes.map(\.id) == [quote.id])
        #expect(try db.search("don’t").quotes.map(\.id) == [quote.id])
    }

    // These all mean something in FTS5's query language. Typed into a raw query, they'd be errors.
    @Test func typingNeverBreaksTheQuery() throws {
        let db = try AppDatabase.inMemory()
        let quote = try db.createQuote(text: "Not all who wander are lost")
        let awkward = [
            "\"", "\"\"", "*", "-", ":", "(", ")", "^", "+", "NOT", "AND", "OR", "NEAR(",
            "not*", "wander\"", "\"wander", "wan\"der", "title:wander", "-wander", "(wander",
            "wander OR", "'", "''", ";--", "%", "\\", "\u{0}", "😀", "ª", "١",
        ]
        for typed in awkward {
            _ = try db.search(typed)
            _ = try db.quotes(matching: typed)
        }
        #expect(try db.search("not").quotes.map(\.id) == [quote.id])
        #expect(try db.search("wander\"").quotes.map(\.id) == [quote.id])
    }

    @Test func blankOrPunctuationOnlySearchesFindNothing() throws {
        let db = try AppDatabase.inMemory()
        try db.createQuote(text: "Anything at all")
        for typed in ["", "   ", "\n", "--", "\"\""] {
            #expect(try db.search(typed).isEmpty)
        }
    }

    @Test func resultsAreCappedPerKindSoPagesCannotPushOutQuotes() throws {
        let db = try AppDatabase.inMemory()
        let section = try emptySection(db)
        for _ in 0..<(AppDatabase.searchResultLimit + 5) {
            try db.createPage(title: "Soup", sectionId: section.id)
        }
        try db.createQuote(text: "Soup is a hug")

        let results = try db.search("soup")
        #expect(results.pages.count == AppDatabase.searchResultLimit)
        #expect(results.quotes.count == 1)
    }

    @Test func updatesArriveWhenTheJournalChanges() async throws {
        let db = try AppDatabase.inMemory()
        var iterator = db.searchUpdates("orchard").makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)

        let quote = try db.createQuote(text: "The orchard in spring")
        #expect(try await iterator.next()?.quotes.map(\.id) == [quote.id])

        try db.deleteQuote(id: quote.id)
        #expect(try await iterator.next()?.isEmpty == true)
    }
}

@Suite struct SearchIndexTests {
    @Test func rebuildingRestoresEverythingLiveAndNothingDeleted() throws {
        let db = try AppDatabase.inMemory()
        let section = try emptySection(db)
        let page = try db.createPage(title: "Tomato soup", sectionId: section.id)
        try db.savePageDocument(document("Roast the garlic"), id: page.id)
        let gone = try db.createPage(title: "Tomato salad", sectionId: section.id)
        try db.deletePage(id: gone.id)
        let quote = try db.createQuote(text: "Tomatoes are a fruit", author: "Sam", tags: ["food"])

        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM search_index")
            try db.execute(sql: "DELETE FROM search_item")
        }
        #expect(try db.search("tomato").isEmpty)

        try db.rebuildSearchIndex()

        let results = try db.search("tomato")
        #expect(results.pages.map(\.id) == [page.id])
        #expect(results.quotes.map(\.id) == [quote.id])
        #expect(try db.search("garlic").pages.map(\.id) == [page.id])
        #expect(try db.search("food").quotes.map(\.id) == [quote.id])
    }

    // What happens on Alex's devices: pages already exist when this version first opens.
    @Test func upgradingIndexesExistingPages() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1: notebook tree and pages")
        let id = UUID()
        let body = try document("Written before search existed").encoded()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO page (id, section_id, title, body, sort_order, created_at, modified_at, deleted_at)
                    VALUES (?, ?, ?, ?, 1, ?, ?, NULL)
                    """,
                arguments: [id, UUID(), "Old page", body, Date(), Date()]
            )
        }

        let db = try AppDatabase(queue)

        #expect(try db.search("written").pages.map(\.id) == [id])
        #expect(try db.search("old").pages.map(\.id) == [id])
    }

    @Test func aPageFromANewerVersionIsStillFoundByItsTitle() throws {
        let db = try AppDatabase.inMemory()
        let page = try db.createPage(title: "From the future", sectionId: try emptySection(db).id)
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE page SET body = ? WHERE id = ?",
                arguments: [Data(#"{"version":9999,"blocks":[]}"#.utf8), page.id]
            )
        }

        try db.rebuildSearchIndex()

        #expect(try db.search("future").pages.map(\.id) == [page.id])
        #expect(throws: (any Error).self) { try db.pageDocument(id: page.id) }
    }

    @Test func aPageIsOnlyEverIndexedOnce() throws {
        let db = try AppDatabase.inMemory()
        let page = try db.createPage(title: "Soup", sectionId: try emptySection(db).id)
        for index in 0..<5 {
            try db.savePageDocument(document("Version \(index)"), id: page.id)
        }
        let counts = try db.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_item"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index"))
        }
        #expect(counts.0 == 1)
        #expect(counts.1 == 1)
    }

    // The target is "feels instant": 2 screen refreshes or so per keystroke. Larger than the
    // library is likely to get, with a limit generous enough not to fail on a busy machine.
    @Test func searchStaysFastWithAVeryLargeJournal() throws {
        let db = try AppDatabase.inMemory()
        let section = try emptySection(db)
        let words = ["patience", "orchard", "courage", "morning", "harvest", "lantern", "river", "garden", "silence", "journey"]
        try db.writer.write { db in
            for index in 0..<20_000 {
                let quote = Quote(
                    text: (0..<20).map { words[(index &* 31 &+ $0 &* 7) % words.count] }.joined(separator: " "),
                    author: "Author \(index % 200)", source: "Book \(index % 500)", tags: [words[index % words.count]],
                    sortOrder: Double(index)
                )
                try quote.insert(db)
                try AppDatabase.indexQuote(quote, db)
            }
            for index in 0..<2_000 {
                let page = Page(sectionId: section.id, title: "Page \(index)", sortOrder: Double(index))
                try page.insert(db)
                try AppDatabase.indexPage(id: page.id, db)
            }
        }

        let clock = ContinuousClock()
        var slowest = Duration.zero
        for typed in ["p", "pa", "pat", "patience", "patience orchard", "author 12", "lantern riv"] {
            let elapsed = try clock.measure { _ = try db.search(typed) }
            slowest = max(slowest, elapsed)
        }
        print("Slowest search across 22,000 items: \(slowest)")
        #expect(slowest < .milliseconds(250))
    }
}

@Suite struct QuoteTests {
    @Test func savingTidiesTheFields() throws {
        let db = try AppDatabase.inMemory()
        let quote = try db.createQuote(
            text: "  Hello\n", author: " Sam ", source: "\tBook ",
            tags: Quote.parseTags("Faith, #hope,, faith ,  ")
        )
        #expect(quote.text == "Hello")
        #expect(quote.author == "Sam")
        #expect(quote.source == "Book")
        #expect(quote.tags == ["Faith", "hope"])
    }

    @Test func tagsSurviveARoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let quote = try db.createQuote(text: "Hello", tags: ["a b", "c,d"])
        #expect(try db.quote(id: quote.id)?.tags == ["a b", "c,d"])
    }

    @Test func listsNewestFirst() throws {
        let db = try AppDatabase.inMemory()
        let first = try db.createQuote(text: "First")
        let second = try db.createQuote(text: "Second")
        #expect(try db.quotes().map(\.id) == [second.id, first.id])
    }

    @Test func updatingChangesTheSearchIndex() throws {
        let db = try AppDatabase.inMemory()
        var quote = try db.createQuote(text: "Old words", author: "Sam", tags: ["before"])
        quote.text = "New words"
        quote.author = "Mira"
        quote.tags = ["after"]
        try db.updateQuote(quote)

        for gone in ["old", "sam", "before"] {
            #expect(try db.search(gone).isEmpty, "\(gone)")
        }
        for found in ["new", "mira", "after"] {
            #expect(try db.search(found).quotes.map(\.id) == [quote.id], "\(found)")
        }
    }

    @Test func deletingHidesItEverywhere() throws {
        let db = try AppDatabase.inMemory()
        let section = try emptySection(db)
        let quote = try db.createQuote(text: "Hello", author: "Sam", tags: ["greeting"], sectionId: section.id)
        try db.deleteQuote(id: quote.id)

        #expect(try db.quote(id: quote.id) == nil)
        #expect(try db.search("hello").isEmpty)
        let library = try db.quoteLibrary()
        #expect(library.quotes.isEmpty)
        #expect(library.tags.isEmpty)
        #expect(library.authors.isEmpty)
        #expect(library.sectionIds.isEmpty)
    }

    @Test func searchesTheLibraryByTextAuthorSourceAndTag() throws {
        let db = try AppDatabase.inMemory()
        let quote = try db.createQuote(text: "Plant the tree", author: "Mira", source: "Letters", tags: ["hope"])
        try db.createQuote(text: "Something else", author: "Tomas", source: "Roads", tags: ["courage"])

        for typed in ["plant", "mira", "letters", "hope"] {
            #expect(try db.quotes(matching: typed).map(\.id) == [quote.id], "\(typed)")
        }
    }

    @Test func librarySearchLeavesOutPagesWithTheSameWords() throws {
        let db = try AppDatabase.inMemory()
        try db.createPage(title: "Orchard diary", sectionId: try emptySection(db).id)
        let quote = try db.createQuote(text: "The orchard in spring")
        #expect(try db.quotes(matching: "orchard").map(\.id) == [quote.id])
    }

    @Test func filtersByTagAuthorAndSection() throws {
        let db = try AppDatabase.inMemory()
        let section = try emptySection(db)
        let hope = try db.createQuote(text: "One", author: "Mira", tags: ["Hope", "spring"], sectionId: section.id)
        let courage = try db.createQuote(text: "Two", author: "Tomas", tags: ["courage"])

        #expect(try db.quotes(filter: .tag("hope")).map(\.id) == [hope.id])
        #expect(try db.quotes(filter: .tag("courage")).map(\.id) == [courage.id])
        #expect(try db.quotes(filter: .tag("cour")).isEmpty)
        #expect(try db.quotes(filter: .author("mira")).map(\.id) == [hope.id])
        #expect(try db.quotes(filter: .section(section.id)).map(\.id) == [hope.id])
    }

    @Test func searchAndFilterCombine() throws {
        let db = try AppDatabase.inMemory()
        let wanted = try db.createQuote(text: "Plant the tree", tags: ["hope"])
        try db.createQuote(text: "Plant the garden", tags: ["work"])
        try db.createQuote(text: "Water the tree", tags: ["hope"])

        #expect(try db.quotes(matching: "plant", filter: .tag("hope")).map(\.id) == [wanted.id])
    }

    @Test func theFilterMenuCoversTheWholeLibrary() throws {
        let db = try AppDatabase.inMemory()
        try db.createQuote(text: "One", author: "Mira", tags: ["spring", "Hope"])
        try db.createQuote(text: "Two", author: "Tomas", tags: ["hope", "courage"])

        let library = try db.quoteLibrary(filter: .author("Tomas"))
        #expect(library.quotes.count == 1)
        #expect(library.authors == ["Mira", "Tomas"])
        #expect(library.tags.contains("courage"))
        #expect(library.tags.contains("spring"))
    }

    @Test func aRandomQuoteAvoidsTheOneShowing() throws {
        let db = try AppDatabase.inMemory()
        let first = try db.createQuote(text: "One")
        let second = try db.createQuote(text: "Two")
        let library = try db.quoteLibrary()

        for _ in 0..<20 {
            #expect(library.randomQuote(excluding: first.id)?.id == second.id)
        }
        // Nothing else to offer, so the same one comes back rather than nothing.
        let single = try db.quoteLibrary(matching: "one")
        #expect(single.randomQuote(excluding: first.id)?.id == first.id)
        #expect(QuoteLibrary().randomQuote(excluding: nil) == nil)
    }

    @Test func becomesQuoteBlocksWithAnAttribution() throws {
        let db = try AppDatabase.inMemory()
        let quote = try db.createQuote(text: "Line one\nLine two", author: "Mira", source: "Letters")

        #expect(quote.blocks.map(\.kind) == [.quote, .quote, .quote])
        #expect(quote.blocks.map(\.plainText) == ["Line one", "Line two", "— Mira, Letters"])
        #expect(quote.blocks[2].runs[0].style.slant == .italic)

        let unattributed = try db.createQuote(text: "Alone")
        #expect(unattributed.blocks.map(\.plainText) == ["Alone"])
    }

    @Test func sampleDataIncludesSearchableQuotes() throws {
        let db = try AppDatabase.inMemory()
        try db.addSampleData()
        #expect(try db.search("orchard").quotes.count == 2)
        #expect(try db.search("roast").pages.count == 1)
    }
}
