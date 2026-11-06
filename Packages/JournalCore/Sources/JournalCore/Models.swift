// The journal's stored types: notebooks, section groups, sections, pages and quotes.
//
// Every record has a UUID, plus modified and deleted dates. iCloud sync needs these later:
// UUIDs can be created offline on any device without clashing, and a deleted date lets a
// delete reach other devices, which a removed row could not do.

import Foundation
import GRDB

public protocol JournalRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable where ID == UUID {
    var id: UUID { get }
    var sortOrder: Double { get set }
    var modifiedAt: Date { get set }
    var deletedAt: Date? { get set }
}

// Swift uses names like `sortOrder`, and the database uses `sort_order`.
extension JournalRecord {
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
}

// The colors a notebook or section can have. The database stores the name, not the shade, so
// each theme can show the shade that reads best on it.
public enum ItemColor: String, CaseIterable, Sendable {
    case red, orange, yellow, green, teal, cyan, blue, indigo, purple, pink, brown, gray
}

public struct Notebook: JournalRecord {
    public static let databaseTableName = "notebook"

    public var id = UUID()
    public var name: String
    // Kept as text so a color added by a newer version of the app can't stop this row loading.
    public var colorName: String?
    public var sortOrder: Double
    public var createdAt = Date()
    public var modifiedAt = Date()
    public var deletedAt: Date?

    public var color: ItemColor? { colorName.flatMap(ItemColor.init) }
}

public struct SectionGroup: JournalRecord {
    public static let databaseTableName = "section_group"

    public var id = UUID()
    public var notebookId: UUID
    // Nil means the group sits directly in the notebook. Otherwise it's nested in this group.
    public var parentGroupId: UUID?
    public var name: String
    public var sortOrder: Double
    public var createdAt = Date()
    public var modifiedAt = Date()
    public var deletedAt: Date?
}

// Named NoteSection because SwiftUI already has a type called Section.
public struct NoteSection: JournalRecord {
    public static let databaseTableName = "section"

    public var id = UUID()
    public var notebookId: UUID
    public var groupId: UUID?
    public var name: String
    // Kept as text so a color added by a newer version of the app can't stop this row loading.
    public var colorName: String?
    public var sortOrder: Double
    public var createdAt = Date()
    public var modifiedAt = Date()
    public var deletedAt: Date?

    public var color: ItemColor? { colorName.flatMap(ItemColor.init) }
}

// The page body stays in the database but out of this type, so listing pages stays fast
// however long the pages get.
public struct Page: JournalRecord {
    public static let databaseTableName = "page"

    public var id = UUID()
    public var sectionId: UUID
    public var title: String
    public var sortOrder: Double
    public var createdAt = Date()
    public var modifiedAt = Date()
    public var deletedAt: Date?
}

public struct Quote: JournalRecord {
    public static let databaseTableName = "quote"

    public var id = UUID()
    public var text: String
    public var author: String
    // Where the quote came from: a book, a talk, a film.
    public var source: String
    // Stored in the row as JSON, so a quote and its tags stay one record when syncing.
    public var tags: [String]
    // An optional home in the notebook tree, like filing a quote under "Book notes".
    public var sectionId: UUID?
    // The page the quote was saved from, if any.
    public var pageId: UUID?
    public var sortOrder: Double
    public var createdAt = Date()
    public var modifiedAt = Date()
    public var deletedAt: Date?
}
