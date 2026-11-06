// Full-text search over pages and quotes.
//
// The search tables are only a fast way to look things up. Pages and quotes stay the truth, so
// the index is updated in the same database transaction as the change it reflects, and
// rebuildSearchIndex can recreate all of it from them.

import Foundation
import GRDB

// A piece of a search result's text. Matching words are drawn differently.
public struct SnippetPart: Hashable, Sendable {
    public var text: String
    public var isMatch: Bool
}

public struct PageSearchResult: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sectionId: UUID
    public var title: [SnippetPart]
    public var snippet: [SnippetPart]
}

public struct QuoteSearchResult: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var author: String
    public var snippet: [SnippetPart]
}

// How much of the journal a search covers.
public enum SearchScope: Hashable, Sendable {
    case everything
    // A notebook, section group or section, including everything inside it.
    case item(TreeItemRef)
}

public struct SearchResults: Equatable, Sendable {
    public var pages: [PageSearchResult] = []
    public var quotes: [QuoteSearchResult] = []

    public init() {}

    public var isEmpty: Bool { pages.isEmpty && quotes.isEmpty }
}

extension AppDatabase {
    // Each kind is capped separately, so a flood of page matches can't push out the quotes.
    public static let searchResultLimit = 50

    // A title match counts for more than a match in a page's text. Same order as the columns.
    static let rankExpression = "bm25(search_index, 10.0, 1.0, 5.0)"

    // Mark the matching words in FTS5's output. Private-use characters can't appear in typing.
    private static let matchStart = "\u{E000}"
    private static let matchEnd = "\u{E001}"

    // MARK: Searching

    public func search(_ text: String, in scope: SearchScope = .everything) throws -> SearchResults {
        try writer.read { try Self.fetchResults(text, scope, $0) }
    }

    // Delivers the results now, and again whenever the journal changes.
    public func searchUpdates(_ text: String, in scope: SearchScope = .everything) -> AsyncThrowingStream<SearchResults, Error> {
        updates { try Self.fetchResults(text, scope, $0) }
    }

    private static func fetchResults(_ text: String, _ scope: SearchScope, _ db: Database) throws -> SearchResults {
        var results = SearchResults()
        guard let match = matchExpression(for: text) else { return results }

        // A scope becomes the list of sections inside it, since pages and quotes only record
        // their section. Reading the tree here also means the results update if it changes.
        var sectionIds: [UUID] = []
        var pageScope = ""
        var quoteScope = ""
        if case .item(let ref) = scope {
            sectionIds = try fetchTree(db).sectionIds(inside: ref)
            guard !sectionIds.isEmpty else { return results }
            let marks = databaseQuestionMarks(count: sectionIds.count)
            pageScope = "AND page.section_id IN (\(marks))"
            quoteScope = "AND quote.section_id IN (\(marks))"
        }

        // CROSS JOIN makes SQLite start from search_index and go outward. FTS5's snippet and
        // highlight functions only work when the search table is read first.
        let pageRows = try Row.fetchAll(db, sql: """
            SELECT page.id, page.section_id,
                   highlight(search_index, 0, ?, ?) AS title,
                   snippet(search_index, 1, ?, ?, '…', 24) AS snippet
            FROM search_index
            CROSS JOIN search_item ON search_item.id = search_index.rowid
            CROSS JOIN page ON page.id = search_item.item_id
            WHERE search_index MATCH ? AND search_item.kind = 'page' AND page.deleted_at IS NULL \(pageScope)
            ORDER BY \(rankExpression)
            LIMIT ?
            """, arguments: StatementArguments(
                [matchStart, matchEnd, matchStart, matchEnd, match] + sectionIds + [searchResultLimit]
            ))
        results.pages = pageRows.map { row in
            PageSearchResult(
                id: row["id"],
                sectionId: row["section_id"],
                title: parts(of: row["title"]),
                snippet: parts(of: row["snippet"])
            )
        }

        let quoteRows = try Row.fetchAll(db, sql: """
            SELECT quote.id, quote.author,
                   snippet(search_index, 1, ?, ?, '…', 32) AS snippet
            FROM search_index
            CROSS JOIN search_item ON search_item.id = search_index.rowid
            CROSS JOIN quote ON quote.id = search_item.item_id
            WHERE search_index MATCH ? AND search_item.kind = 'quote' AND quote.deleted_at IS NULL \(quoteScope)
            ORDER BY \(rankExpression)
            LIMIT ?
            """, arguments: StatementArguments(
                [matchStart, matchEnd, match] + sectionIds + [searchResultLimit]
            ))
        results.quotes = quoteRows.map { row in
            QuoteSearchResult(id: row["id"], author: row["author"], snippet: parts(of: row["snippet"]))
        }
        return results
    }

    // Turns typing into an FTS5 query. FTS5 has its own query language where characters like
    // " * : - and words like NOT mean something, and a stray one is an error. So every word
    // goes inside quotes, which makes it plain text. The * lets a half-typed word match.
    // Returns nil if there's nothing to search for, such as only punctuation.
    static func matchExpression(for text: String) -> String? {
        let words = text
            .split(whereSeparator: \.isWhitespace)
            .filter { word in word.contains { $0.isLetter || $0.isNumber } }
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func parts(of marked: String) -> [SnippetPart] {
        var parts: [SnippetPart] = []
        for (index, piece) in marked.components(separatedBy: matchStart).enumerated() {
            let pieces = piece.components(separatedBy: matchEnd)
            // Everything before the first start mark is outside a match. After that, each piece
            // is a match followed by the plain text up to the next match.
            if index > 0, pieces.count == 2 {
                if !pieces[0].isEmpty { parts.append(SnippetPart(text: pieces[0], isMatch: true)) }
                if !pieces[1].isEmpty { parts.append(SnippetPart(text: pieces[1], isMatch: false)) }
            } else if !piece.isEmpty {
                parts.append(SnippetPart(text: piece, isMatch: false))
            }
        }
        return parts
    }

    // MARK: Keeping the index up to date

    // Reads the page's current title and text and replaces its index entry.
    static func indexPage(id: UUID, _ db: Database) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT title, body FROM page WHERE id = ? AND deleted_at IS NULL",
            arguments: [id]
        ) else {
            try removeFromSearchIndex(id: id, db)
            return
        }
        try setSearchEntry(kind: "page", id: id, title: row["title"], body: plainText(ofBody: row["body"]), details: "", db)
    }

    static func indexQuote(_ quote: Quote, _ db: Database) throws {
        let details = ([quote.author, quote.source] + quote.tags).joined(separator: " ")
        try setSearchEntry(kind: "quote", id: quote.id, title: "", body: quote.text, details: details, db)
    }

    static func removeFromSearchIndex(id: UUID, _ db: Database) throws {
        guard let rowId = try Int64.fetchOne(db, sql: "SELECT id FROM search_item WHERE item_id = ?", arguments: [id]) else {
            return
        }
        try db.execute(sql: "DELETE FROM search_index WHERE rowid = ?", arguments: [rowId])
        try db.execute(sql: "DELETE FROM search_item WHERE id = ?", arguments: [rowId])
    }

    private static func setSearchEntry(
        kind: String, id: UUID, title: String, body: String, details: String, _ db: Database
    ) throws {
        try removeFromSearchIndex(id: id, db)
        try db.execute(sql: "INSERT INTO search_item (kind, item_id) VALUES (?, ?)", arguments: [kind, id])
        try db.execute(
            sql: "INSERT INTO search_index (rowid, title, body, details) VALUES (?, ?, ?, ?)",
            arguments: [db.lastInsertedRowID, title, body, details]
        )
    }

    // A page this version can't read is still found by its title. Failing here would block the
    // save or the app upgrade over something that only affects search.
    private static func plainText(ofBody body: Data?) -> String {
        guard let body, let document = try? PageDocument.decoded(from: body) else { return "" }
        return document.plainText
    }

    // MARK: Rebuilding

    public func rebuildSearchIndex() throws {
        try writer.write(Self.rebuildSearchIndex)
    }

    static func rebuildSearchIndex(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM search_index")
        try db.execute(sql: "DELETE FROM search_item")
        let pageIds = try UUID.fetchAll(db, sql: "SELECT id FROM page WHERE deleted_at IS NULL")
        for id in pageIds {
            try indexPage(id: id, db)
        }
        for quote in try Quote.filter(Column("deleted_at") == nil).fetchAll(db) {
            try indexQuote(quote, db)
        }
    }
}
