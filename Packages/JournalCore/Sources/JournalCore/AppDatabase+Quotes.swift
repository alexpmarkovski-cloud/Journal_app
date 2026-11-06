// Saving quotes and reading the quote library.

import Foundation
import GRDB

// One way to narrow the library. Tapping a tag, an author or a section picks one of these.
public enum QuoteFilter: Hashable, Sendable {
    case tag(String)
    case author(String)
    case section(UUID)
}

// Everything the library screen shows, read together so the parts always agree.
public struct QuoteLibrary: Equatable, Sendable {
    public var quotes: [Quote] = []
    // These cover the whole library, so the filter menu doesn't shrink as a filter is applied.
    public var tags: [String] = []
    public var authors: [String] = []
    public var sectionIds: [UUID] = []

    public init() {}

    // A random quote from what's listed, which is never the one already showing unless it's the
    // only one. Asking again should always feel like getting something new.
    public func randomQuote(excluding currentId: UUID?) -> Quote? {
        let others = quotes.filter { $0.id != currentId }
        return others.randomElement() ?? quotes.first
    }
}

extension Quote {
    // Splits typed tags on commas, drops a leading # and blanks, and removes repeats whatever
    // their capitals are. So "Faith, #hope, faith" becomes ["Faith", "hope"].
    public static func parseTags(_ text: String) -> [String] {
        cleanTags(text.split(separator: ",").map(String.init))
    }

    private static func cleanTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            var clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            while clean.hasPrefix("#") { clean.removeFirst() }
            clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { return nil }
            return clean
        }
    }

    fileprivate mutating func tidy() {
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        tags = Self.cleanTags(tags)
    }

    // "Author, Source", leaving out whichever is blank.
    public var attribution: String {
        [author, source].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // How the quote looks when placed in a page: its text in quote blocks, then who said it.
    public var blocks: [Block] {
        var blocks = text
            .split(whereSeparator: \.isNewline)
            .map { Block(kind: .quote, runs: [TextRun(String($0))]) }
        if !attribution.isEmpty {
            var style = TextStyle()
            style.slant = .italic
            blocks.append(Block(kind: .quote, runs: [TextRun("— " + attribution, style: style)]))
        }
        return blocks
    }
}

extension AppDatabase {
    // MARK: Saving

    @discardableResult
    public func createQuote(
        text: String,
        author: String = "",
        source: String = "",
        tags: [String] = [],
        sectionId: UUID? = nil,
        pageId: UUID? = nil
    ) throws -> Quote {
        try writer.write { db in
            // Newest first, and a time keeps that order correct across devices.
            var quote = Quote(
                text: text, author: author, source: source, tags: tags,
                sectionId: sectionId, pageId: pageId,
                sortOrder: Date().timeIntervalSince1970
            )
            quote.tidy()
            try quote.insert(db)
            try Self.indexQuote(quote, db)
            return quote
        }
    }

    public func updateQuote(_ quote: Quote) throws {
        try writer.write { db in
            var updated = quote
            updated.tidy()
            updated.modifiedAt = Date()
            try updated.update(db)
            try Self.indexQuote(updated, db)
        }
    }

    public func deleteQuote(id: UUID) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(
                sql: "UPDATE quote SET deleted_at = ?, modified_at = ? WHERE id = ?",
                arguments: [now, now, id]
            )
            try Self.removeFromSearchIndex(id: id, db)
        }
    }

    // MARK: Reading

    public func quote(id: UUID) throws -> Quote? {
        try writer.read { db in
            try Quote.filter(Column("id") == id && Column("deleted_at") == nil).fetchOne(db)
        }
    }

    public func quotes(matching search: String = "", filter: QuoteFilter? = nil, limit: Int? = nil) throws -> [Quote] {
        try writer.read { try Self.fetchQuotes(search, filter, limit, $0) }
    }

    public func quoteLibrary(matching search: String = "", filter: QuoteFilter? = nil) throws -> QuoteLibrary {
        try writer.read { try Self.fetchLibrary(search, filter, $0) }
    }

    // Delivers the library now, and again whenever it changes.
    public func quoteLibraryUpdates(matching search: String, filter: QuoteFilter?) -> AsyncThrowingStream<QuoteLibrary, Error> {
        updates { try Self.fetchLibrary(search, filter, $0) }
    }

    private static func fetchLibrary(_ search: String, _ filter: QuoteFilter?, _ db: Database) throws -> QuoteLibrary {
        var library = QuoteLibrary()
        library.quotes = try fetchQuotes(search, filter, nil, db)
        library.tags = try String.fetchAll(db, sql: """
            SELECT DISTINCT value FROM quote, json_each(quote.tags)
            WHERE quote.deleted_at IS NULL
            ORDER BY value COLLATE NOCASE
            """)
        library.authors = try String.fetchAll(db, sql: """
            SELECT DISTINCT author FROM quote
            WHERE deleted_at IS NULL AND author != ''
            ORDER BY author COLLATE NOCASE
            """)
        library.sectionIds = try UUID.fetchAll(db, sql: """
            SELECT DISTINCT section_id FROM quote
            WHERE deleted_at IS NULL AND section_id IS NOT NULL
            """)
        return library
    }

    private static func fetchQuotes(_ search: String, _ filter: QuoteFilter?, _ limit: Int?, _ db: Database) throws -> [Quote] {
        var conditions = ["quote.deleted_at IS NULL"]
        var arguments: [any DatabaseValueConvertible] = []

        // Search terms come first, because they fill the first ? in the query below.
        var from = "quote"
        var order = "quote.sort_order DESC"
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let match = matchExpression(for: search) else { return [] }
            from = """
                search_index
                CROSS JOIN search_item ON search_item.id = search_index.rowid
                CROSS JOIN quote ON quote.id = search_item.item_id
                """
            conditions.append("search_index MATCH ?")
            arguments.append(match)
            order = rankExpression
        }

        switch filter {
        case .tag(let tag):
            conditions.append("EXISTS (SELECT 1 FROM json_each(quote.tags) WHERE value = ? COLLATE NOCASE)")
            arguments.append(tag)
        case .author(let author):
            conditions.append("quote.author = ? COLLATE NOCASE")
            arguments.append(author)
        case .section(let sectionId):
            conditions.append("quote.section_id = ?")
            arguments.append(sectionId)
        case nil:
            break
        }

        var sql = "SELECT quote.* FROM \(from) WHERE \(conditions.joined(separator: " AND ")) ORDER BY \(order)"
        if let limit {
            sql += " LIMIT ?"
            arguments.append(limit)
        }
        return try Quote.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    }
}
