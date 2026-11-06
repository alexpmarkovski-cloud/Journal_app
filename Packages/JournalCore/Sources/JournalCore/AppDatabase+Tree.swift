// Creating, renaming, deleting and moving notebooks, section groups and sections.

import Foundation
import GRDB

extension AppDatabase {
    // MARK: Reading

    static func fetchTree(_ db: Database) throws -> JournalTree {
        let isLive = Column("deleted_at") == nil
        let order = Column("sort_order")
        return JournalTree(
            notebooks: try Notebook.filter(isLive).order(order).fetchAll(db),
            groups: try SectionGroup.filter(isLive).order(order).fetchAll(db),
            sections: try NoteSection.filter(isLive).order(order).fetchAll(db)
        )
    }

    public func tree() throws -> JournalTree {
        try writer.read(Self.fetchTree)
    }

    // Delivers the tree now, and again whenever it changes.
    public func treeUpdates() -> AsyncThrowingStream<JournalTree, Error> {
        updates(Self.fetchTree)
    }

    func updates<Value: Equatable & Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, Error> {
        let writer = self.writer
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let observation = ValueObservation.tracking(fetch).removeDuplicates()
                    for try await value in observation.values(in: writer) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Creating

    @discardableResult
    public func createNotebook(name: String) throws -> Notebook {
        try writer.write { db in
            let last = try Self.fetchTree(db).notebooks.last?.sortOrder
            let notebook = Notebook(name: name, sortOrder: (last ?? 0) + 1)
            try notebook.insert(db)
            return notebook
        }
    }

    // `parent` is the notebook or group that will hold the new group.
    @discardableResult
    public func createGroup(name: String, in parent: TreeItemRef) throws -> SectionGroup {
        try writer.write { db in
            let tree = try Self.fetchTree(db)
            let (notebookId, groupId) = try Self.location(of: parent, in: tree)
            let last = tree.children(notebookId: notebookId, groupId: groupId).last?.sortOrder
            let group = SectionGroup(notebookId: notebookId, parentGroupId: groupId, name: name, sortOrder: (last ?? 0) + 1)
            try group.insert(db)
            return group
        }
    }

    @discardableResult
    public func createSection(name: String, in parent: TreeItemRef) throws -> NoteSection {
        try writer.write { db in
            let tree = try Self.fetchTree(db)
            let (notebookId, groupId) = try Self.location(of: parent, in: tree)
            let last = tree.children(notebookId: notebookId, groupId: groupId).last?.sortOrder
            let section = NoteSection(notebookId: notebookId, groupId: groupId, name: name, sortOrder: (last ?? 0) + 1)
            try section.insert(db)
            return section
        }
    }

    private static func location(of parent: TreeItemRef, in tree: JournalTree) throws -> (notebookId: UUID, groupId: UUID?) {
        switch parent.kind {
        case .notebook:
            return (parent.id, nil)
        case .group:
            guard let group = tree.groups.first(where: { $0.id == parent.id }) else { throw JournalError.itemNotFound }
            return (group.notebookId, group.id)
        case .section:
            throw JournalError.invalidParent
        }
    }

    // MARK: Renaming and deleting

    public func rename(_ ref: TreeItemRef, to name: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE \(Self.table(for: ref.kind)) SET name = ?, modified_at = ? WHERE id = ?",
                arguments: [name, Date(), ref.id]
            )
        }
    }

    // Nil takes the color away. Section groups don't have colors.
    public func setColor(_ color: ItemColor?, of ref: TreeItemRef) throws {
        guard ref.kind != .group else { throw JournalError.invalidParent }
        try writer.write { db in
            try db.execute(
                sql: "UPDATE \(Self.table(for: ref.kind)) SET color_name = ?, modified_at = ? WHERE id = ?",
                arguments: [color?.rawValue, Date(), ref.id]
            )
        }
    }

    // Marks the item and everything inside it as deleted. Nothing is erased, so the Trash can
    // restore it later.
    public func delete(_ ref: TreeItemRef) throws {
        try writer.write { db in
            let tree = try Self.fetchTree(db)
            let now = Date()
            var groupIds: [UUID] = []
            var sectionIds: [UUID] = []

            switch ref.kind {
            case .notebook:
                try Self.markDeleted("notebook", ids: [ref.id], at: now, db)
                groupIds = tree.groups.filter { $0.notebookId == ref.id }.map(\.id)
                sectionIds = tree.sections.filter { $0.notebookId == ref.id }.map(\.id)
            case .group:
                groupIds = [ref.id] + tree.descendantGroupIds(of: ref.id)
                sectionIds = tree.sections.filter { $0.groupId.map(groupIds.contains) ?? false }.map(\.id)
            case .section:
                sectionIds = [ref.id]
            }

            try Self.markDeleted("section_group", ids: groupIds, at: now, db)
            try Self.markDeleted("section", ids: sectionIds, at: now, db)
            for sectionId in sectionIds {
                let pageIds = try UUID.fetchAll(
                    db,
                    sql: "SELECT id FROM page WHERE section_id = ? AND deleted_at IS NULL",
                    arguments: [sectionId]
                )
                for pageId in pageIds {
                    try Self.removeFromSearchIndex(id: pageId, db)
                }
                try db.execute(
                    sql: "UPDATE page SET deleted_at = ?, modified_at = ? WHERE section_id = ? AND deleted_at IS NULL",
                    arguments: [now, now, sectionId]
                )
            }
        }
    }

    private static func markDeleted(_ table: String, ids: [UUID], at date: Date, _ db: Database) throws {
        for id in ids {
            try db.execute(
                sql: "UPDATE \(table) SET deleted_at = ?, modified_at = ? WHERE id = ?",
                arguments: [date, date, id]
            )
        }
    }

    private static func table(for kind: TreeItemKind) -> String {
        switch kind {
        case .notebook: "notebook"
        case .group: "section_group"
        case .section: "section"
        }
    }

    // MARK: Moving

    // Moves an item into the gap just below `above`, a row in the sidebar. Nil means the very top.
    //
    // The row above decides where the item ends up:
    // - an open notebook or group: the item becomes its first child
    // - a closed notebook: the item goes inside it, at the end
    // - a closed group or a section: the item goes right after it, at the same level
    // A notebook stays at the top level, after the notebook that row belongs to.
    // Moves that make no sense, like a group into its own subgroup, are ignored.
    public func move(_ item: TreeItemRef, below above: TreeRow?) throws {
        guard item != above?.ref else { return }
        try writer.write { db in
            let tree = try Self.fetchTree(db)

            if item.kind == .notebook {
                let siblings = tree.notebooks.filter { $0.id != item.id }
                var index = 0
                if let above {
                    let owner = tree.notebookId(of: above.ref)
                    guard owner != item.id else { return }
                    index = (siblings.firstIndex { $0.id == owner } ?? siblings.count - 1) + 1
                }
                let order = try Self.makeRoom(
                    siblings.map { Sibling(table: "notebook", id: $0.id, sortOrder: $0.sortOrder) },
                    at: index, db
                )
                try db.execute(
                    sql: "UPDATE notebook SET sort_order = ?, modified_at = ? WHERE id = ?",
                    arguments: [order, Date(), item.id]
                )
                return
            }

            // Nothing but a notebook can sit at the very top.
            guard let above else { return }

            // Work out which notebook or group the item is going into, and after which sibling.
            let notebookId: UUID
            let groupId: UUID?
            var afterItem: UUID?
            var goesFirst = false
            switch above.ref.kind {
            case .notebook:
                notebookId = above.ref.id
                groupId = nil
                goesFirst = above.isExpanded
            case .group:
                guard let group = tree.groups.first(where: { $0.id == above.ref.id }) else { return }
                notebookId = group.notebookId
                groupId = above.isExpanded ? group.id : group.parentGroupId
                goesFirst = above.isExpanded
                afterItem = above.isExpanded ? nil : group.id
            case .section:
                guard let section = tree.sections.first(where: { $0.id == above.ref.id }) else { return }
                notebookId = section.notebookId
                groupId = section.groupId
                afterItem = section.id
            }

            if item.kind == .group, let groupId {
                let blocked = [item.id] + tree.descendantGroupIds(of: item.id)
                guard !blocked.contains(groupId) else { return }
            }

            let siblings = tree.children(notebookId: notebookId, groupId: groupId).filter { $0.ref != item }
            let index = goesFirst ? 0 : afterItem.flatMap { id in
                siblings.firstIndex { $0.ref.id == id }.map { $0 + 1 }
            } ?? siblings.count
            let order = try Self.makeRoom(
                siblings.map { Sibling(table: Self.table(for: $0.ref.kind), id: $0.ref.id, sortOrder: $0.sortOrder) },
                at: index, db
            )

            let now = Date()
            switch item.kind {
            case .group:
                try db.execute(
                    sql: "UPDATE section_group SET notebook_id = ?, parent_group_id = ?, sort_order = ?, modified_at = ? WHERE id = ?",
                    arguments: [notebookId, groupId, order, now, item.id]
                )
                // Everything inside the group moves to the new notebook with it.
                let inside = tree.descendantGroupIds(of: item.id)
                for id in inside {
                    try db.execute(
                        sql: "UPDATE section_group SET notebook_id = ?, modified_at = ? WHERE id = ?",
                        arguments: [notebookId, now, id]
                    )
                }
                for section in tree.sections where section.groupId.map({ ([item.id] + inside).contains($0) }) ?? false {
                    try db.execute(
                        sql: "UPDATE section SET notebook_id = ?, modified_at = ? WHERE id = ?",
                        arguments: [notebookId, now, section.id]
                    )
                }
            case .section:
                try db.execute(
                    sql: "UPDATE section SET notebook_id = ?, group_id = ?, sort_order = ?, modified_at = ? WHERE id = ?",
                    arguments: [notebookId, groupId, order, now, item.id]
                )
            case .notebook:
                break
            }
        }
    }

    // MARK: Ordering

    struct Sibling {
        var table: String
        var id: UUID
        var sortOrder: Double
    }

    // Returns a sort order that places an item at `index` among its siblings.
    //
    // It picks the number halfway between the two neighbors, so a move only changes the moved
    // item. That matters for sync, because fewer changed records means fewer conflicts. After
    // many moves into the same gap the numbers run out of precision, and only then are the
    // siblings renumbered.
    static func makeRoom(_ siblings: [Sibling], at index: Int, _ db: Database) throws -> Double {
        if let order = sortOrder(before: index > 0 ? siblings[index - 1].sortOrder : nil,
                                 after: index < siblings.count ? siblings[index].sortOrder : nil) {
            return order
        }
        let now = Date()
        for (position, sibling) in siblings.enumerated() {
            let number = Double(position < index ? position + 1 : position + 2)
            try db.execute(
                sql: "UPDATE \(sibling.table) SET sort_order = ?, modified_at = ? WHERE id = ?",
                arguments: [number, now, sibling.id]
            )
        }
        return Double(index + 1)
    }

    static func sortOrder(before: Double?, after: Double?) -> Double? {
        switch (before, after) {
        case (nil, nil): return 1
        case (nil, let after?): return after - 1
        case (let before?, nil): return before + 1
        case (let before?, let after?):
            let middle = (before + after) / 2
            return middle > before && middle < after ? middle : nil
        }
    }
}

public enum JournalError: Error {
    case itemNotFound
    case invalidParent
    case pageTooNew
}
