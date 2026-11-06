// Opens the SQLite database and creates its tables.
//
// Tables are created through numbered migrations. Each one runs once per device, in order,
// so later versions of the app can change the tables without losing anyone's data.

import Foundation
import GRDB

public struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    // The real journal, stored in the app's private Application Support folder.
    public static func openDefault() throws -> AppDatabase {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Journal", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: folder.appendingPathComponent("journal.sqlite").path)
        return try AppDatabase(pool)
    }

    // A temporary database for tests.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Parent IDs are plain indexed columns, not enforced foreign keys. Sync can deliver a
        // page before its section arrives, and an enforced key would reject that page.
        migrator.registerMigration("v1: notebook tree and pages") { db in
            try db.create(table: "notebook") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("sort_order", .double).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("modified_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
            }
            try db.create(table: "section_group") { t in
                t.primaryKey("id", .blob)
                t.column("notebook_id", .blob).notNull().indexed()
                t.column("parent_group_id", .blob).indexed()
                t.column("name", .text).notNull()
                t.column("sort_order", .double).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("modified_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
            }
            try db.create(table: "section") { t in
                t.primaryKey("id", .blob)
                t.column("notebook_id", .blob).notNull().indexed()
                t.column("group_id", .blob).indexed()
                t.column("name", .text).notNull()
                t.column("sort_order", .double).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("modified_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
            }
            try db.create(table: "page") { t in
                t.primaryKey("id", .blob)
                t.column("section_id", .blob).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("body", .blob)
                t.column("sort_order", .double).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("modified_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
            }
        }

        // search_index is a full-text index: it maps every word to the rows containing it,
        // which is what makes search instant. FTS5 tables identify rows by number, so
        // search_item connects each number to the page or quote it stands for.
        //
        // remove_diacritics means "cafe" finds "café". `prefix` keeps extra lookup lists for
        // the first 2 and 3 letters of each word, so results appear from the first keystrokes.
        //
        // Neither table holds anything new, so both can be rebuilt at any time and neither
        // will sync. Existing pages are indexed here, once, when this version first opens.
        migrator.registerMigration("v2: quotes and search") { db in
            try db.create(table: "quote") { t in
                t.primaryKey("id", .blob)
                t.column("text", .text).notNull()
                t.column("author", .text).notNull()
                t.column("source", .text).notNull()
                t.column("tags", .text).notNull()
                t.column("section_id", .blob).indexed()
                t.column("page_id", .blob).indexed()
                t.column("sort_order", .double).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("modified_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
            }
            try db.create(table: "search_item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("item_id", .blob).notNull().unique()
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search_index USING fts5(
                    title, body, details,
                    tokenize = 'unicode61 remove_diacritics 2',
                    prefix = '2 3'
                )
                """)
            try rebuildSearchIndex(db)
        }

        // Empty means no color chosen, so existing notebooks and sections look as they did.
        migrator.registerMigration("v3: notebook and section colors") { db in
            try db.alter(table: "notebook") { t in
                t.add(column: "color_name", .text)
            }
            try db.alter(table: "section") { t in
                t.add(column: "color_name", .text)
            }
        }
        return migrator
    }
}
