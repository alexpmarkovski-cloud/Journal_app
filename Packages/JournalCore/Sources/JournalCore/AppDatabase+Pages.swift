// Creating, renaming, duplicating, deleting, reordering and moving pages.

import Foundation
import GRDB

extension AppDatabase {
    private static func fetchPages(sectionId: UUID, _ db: Database) throws -> [Page] {
        try Page
            .filter(Column("section_id") == sectionId && Column("deleted_at") == nil)
            .order(Column("sort_order"))
            .fetchAll(db)
    }

    public func pages(sectionId: UUID) throws -> [Page] {
        try writer.read { try Self.fetchPages(sectionId: sectionId, $0) }
    }

    // Delivers the section's pages now, and again whenever they change.
    public func pageUpdates(sectionId: UUID) -> AsyncThrowingStream<[Page], Error> {
        updates { try Self.fetchPages(sectionId: sectionId, $0) }
    }

    public func page(id: UUID) throws -> Page? {
        try writer.read { db in
            try Page.filter(Column("id") == id && Column("deleted_at") == nil).fetchOne(db)
        }
    }

    @discardableResult
    public func createPage(title: String = "", sectionId: UUID) throws -> Page {
        try writer.write { db in
            let last = try Self.fetchPages(sectionId: sectionId, db).last?.sortOrder
            let page = Page(sectionId: sectionId, title: title, sortOrder: (last ?? 0) + 1)
            try page.insert(db)
            try Self.indexPage(id: page.id, db)
            return page
        }
    }

    // Places a copy right below the page. It keeps the original's date, because for a journal
    // entry that's the day it was written. The body is copied as stored, without decoding it, so
    // this also works for a page saved by a newer version of the app.
    @discardableResult
    public func duplicatePage(id: UUID) throws -> Page {
        try writer.write { db in
            guard let original = try Page.filter(Column("id") == id && Column("deleted_at") == nil).fetchOne(db) else {
                throw JournalError.itemNotFound
            }
            let siblings = try Self.fetchPages(sectionId: original.sectionId, db)
            let index = siblings.firstIndex { $0.id == id }.map { $0 + 1 } ?? siblings.count
            let order = try Self.makeRoom(
                siblings.map { Sibling(table: "page", id: $0.id, sortOrder: $0.sortOrder) },
                at: index, db
            )

            var copy = original
            copy.id = UUID()
            copy.title = original.title.isEmpty ? "" : "\(original.title) copy"
            copy.sortOrder = order
            copy.modifiedAt = Date()
            try copy.insert(db)
            try db.execute(
                sql: "UPDATE page SET body = (SELECT body FROM page WHERE id = ?) WHERE id = ?",
                arguments: [id, copy.id]
            )
            try Self.indexPage(id: copy.id, db)
            return copy
        }
    }

    public func renamePage(id: UUID, title: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE page SET title = ?, modified_at = ? WHERE id = ?",
                arguments: [title, Date(), id]
            )
            try Self.indexPage(id: id, db)
        }
    }

    // A page with nothing saved yet comes back as an empty document. A body that can't be read
    // throws instead, so the app can't mistake it for an empty page and save over it.
    public func pageDocument(id: UUID) throws -> PageDocument {
        let data = try writer.read { db in
            try Data.fetchOne(db, sql: "SELECT body FROM page WHERE id = ?", arguments: [id])
        }
        guard let data else { return PageDocument() }
        return try PageDocument.decoded(from: data)
    }

    public func savePageDocument(_ document: PageDocument, id: UUID) throws {
        let data = try document.encoded()
        try writer.write { db in
            try db.execute(
                sql: "UPDATE page SET body = ?, modified_at = ? WHERE id = ?",
                arguments: [data, Date(), id]
            )
            try Self.indexPage(id: id, db)
        }
    }

    public func deletePage(id: UUID) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(
                sql: "UPDATE page SET deleted_at = ?, modified_at = ? WHERE id = ?",
                arguments: [now, now, id]
            )
            try Self.removeFromSearchIndex(id: id, db)
        }
    }

    // Moves a page to the end of another section.
    public func movePage(id: UUID, toSection sectionId: UUID) throws {
        try writer.write { db in
            let last = try Self.fetchPages(sectionId: sectionId, db).last?.sortOrder
            try db.execute(
                sql: "UPDATE page SET section_id = ?, sort_order = ?, modified_at = ? WHERE id = ?",
                arguments: [sectionId, (last ?? 0) + 1, Date(), id]
            )
        }
    }

    // Moves a page within its section. `destination` follows SwiftUI's onMove rule: it's the
    // position in the list as it was before the page was picked up.
    public func reorderPage(id: UUID, sectionId: UUID, toPosition destination: Int) throws {
        try writer.write { db in
            let pages = try Self.fetchPages(sectionId: sectionId, db)
            guard let current = pages.firstIndex(where: { $0.id == id }) else { return }
            let others = pages.filter { $0.id != id }
            let index = min(destination > current ? destination - 1 : destination, others.count)
            let order = try Self.makeRoom(
                others.map { Sibling(table: "page", id: $0.id, sortOrder: $0.sortOrder) },
                at: index, db
            )
            try db.execute(
                sql: "UPDATE page SET sort_order = ?, modified_at = ? WHERE id = ?",
                arguments: [order, Date(), id]
            )
        }
    }
}
