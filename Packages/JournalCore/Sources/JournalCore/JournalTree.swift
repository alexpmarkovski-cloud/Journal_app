// A snapshot of the notebook tree, and the flat list of rows the sidebar draws from it.
//
// The sidebar uses a flat list with indentation instead of a nested one, because a flat list
// lets any row be dragged to any gap, using the same drag behavior on Mac and iPhone.

import Foundation

public enum TreeItemKind: String, Hashable, Sendable {
    case notebook, group, section
}

// Points to one item in the tree without carrying its data.
public struct TreeItemRef: Hashable, Sendable {
    public var kind: TreeItemKind
    public var id: UUID

    public init(kind: TreeItemKind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

public struct TreeRow: Identifiable, Hashable, Sendable {
    public var ref: TreeItemRef
    public var name: String
    public var depth: Int
    public var isExpanded: Bool
    public var color: ItemColor?

    public init(ref: TreeItemRef, name: String = "", depth: Int = 0, isExpanded: Bool = false, color: ItemColor? = nil) {
        self.ref = ref
        self.name = name
        self.depth = depth
        self.isExpanded = isExpanded
        self.color = color
    }

    public var id: UUID { ref.id }
}

public struct JournalTree: Equatable, Sendable {
    public var notebooks: [Notebook] = []
    public var groups: [SectionGroup] = []
    public var sections: [NoteSection] = []

    public init(notebooks: [Notebook] = [], groups: [SectionGroup] = [], sections: [NoteSection] = []) {
        self.notebooks = notebooks
        self.groups = groups
        self.sections = sections
    }

    public var isEmpty: Bool { notebooks.isEmpty }

    public func name(of ref: TreeItemRef) -> String? {
        switch ref.kind {
        case .notebook: notebooks.first { $0.id == ref.id }?.name
        case .group: groups.first { $0.id == ref.id }?.name
        case .section: sections.first { $0.id == ref.id }?.name
        }
    }

    // The notebook and groups an item sits inside, outermost first.
    public func ancestors(of ref: TreeItemRef) -> [TreeItemRef] {
        let notebookId: UUID
        var parentGroupId: UUID?
        switch ref.kind {
        case .notebook:
            return []
        case .group:
            guard let group = groups.first(where: { $0.id == ref.id }) else { return [] }
            notebookId = group.notebookId
            parentGroupId = group.parentGroupId
        case .section:
            guard let section = sections.first(where: { $0.id == ref.id }) else { return [] }
            notebookId = section.notebookId
            parentGroupId = section.groupId
        }
        var groupRefs: [TreeItemRef] = []
        var seen = Set<UUID>()
        while let id = parentGroupId, seen.insert(id).inserted, let group = groups.first(where: { $0.id == id }) {
            groupRefs.insert(TreeItemRef(kind: .group, id: id), at: 0)
            parentGroupId = group.parentGroupId
        }
        return [TreeItemRef(kind: .notebook, id: notebookId)] + groupRefs
    }

    public func ancestors(ofSection id: UUID) -> [TreeItemRef] {
        ancestors(of: TreeItemRef(kind: .section, id: id))
    }

    // Where an item lives, written out: "Personal › Journal 2026 › November".
    public func path(to ref: TreeItemRef) -> String {
        (ancestors(of: ref) + [ref])
            .compactMap(name(of:))
            .joined(separator: " › ")
    }

    public func path(toSection id: UUID) -> String {
        path(to: TreeItemRef(kind: .section, id: id))
    }

    // The same, without the notebook: "Journal 2026 › November".
    public func pathInsideNotebook(to ref: TreeItemRef) -> String {
        (ancestors(of: ref).dropFirst() + [ref])
            .compactMap(name(of:))
            .joined(separator: " › ")
    }

    // Section groups don't have colors.
    public func color(of ref: TreeItemRef) -> ItemColor? {
        switch ref.kind {
        case .notebook: notebooks.first { $0.id == ref.id }?.color
        case .group: nil
        case .section: sections.first { $0.id == ref.id }?.color
        }
    }

    public func notebookId(of ref: TreeItemRef) -> UUID? {
        switch ref.kind {
        case .notebook: ref.id
        case .group: groups.first { $0.id == ref.id }?.notebookId
        case .section: sections.first { $0.id == ref.id }?.notebookId
        }
    }

    func descendantGroupIds(of groupId: UUID) -> [UUID] {
        let children = groups.filter { $0.parentGroupId == groupId }.map(\.id)
        return children + children.flatMap(descendantGroupIds)
    }

    // Every section at or below an item, however deeply it's nested.
    public func sectionIds(inside ref: TreeItemRef) -> [UUID] {
        switch ref.kind {
        case .notebook:
            return sections.filter { $0.notebookId == ref.id }.map(\.id)
        case .group:
            let groupIds = Set([ref.id] + descendantGroupIds(of: ref.id))
            return sections.filter { $0.groupId.map(groupIds.contains) ?? false }.map(\.id)
        case .section:
            return sections.filter { $0.id == ref.id }.map(\.id)
        }
    }

    // The whole tree with everything open, for choosing from.
    public var allRows: [TreeRow] {
        rows(expanded: Set(notebooks.map(\.id) + groups.map(\.id)))
    }

    // A notebook or group's direct children. Groups and sections can be mixed in any order.
    func children(notebookId: UUID, groupId: UUID?) -> [TreeItem] {
        let childGroups = groups
            .filter { $0.notebookId == notebookId && $0.parentGroupId == groupId }
            .map { TreeItem(ref: TreeItemRef(kind: .group, id: $0.id), name: $0.name, sortOrder: $0.sortOrder) }
        let childSections = sections
            .filter { $0.notebookId == notebookId && $0.groupId == groupId }
            .map { TreeItem(ref: TreeItemRef(kind: .section, id: $0.id), name: $0.name, sortOrder: $0.sortOrder, color: $0.color) }
        return (childGroups + childSections).sorted { $0.sortOrder < $1.sortOrder }
    }

    // Walks one notebook top to bottom, skipping anything inside a collapsed group.
    public func rows(inNotebook notebookId: UUID, expanded: Set<UUID>, startingDepth: Int = 0) -> [TreeRow] {
        var rows: [TreeRow] = []

        func addChildren(groupId: UUID?, depth: Int) {
            for child in children(notebookId: notebookId, groupId: groupId) {
                let isExpanded = child.ref.kind == .group && expanded.contains(child.ref.id)
                rows.append(TreeRow(ref: child.ref, name: child.name, depth: depth, isExpanded: isExpanded, color: child.color))
                if isExpanded {
                    addChildren(groupId: child.ref.id, depth: depth + 1)
                }
            }
        }

        addChildren(groupId: nil, depth: startingDepth)
        return rows
    }

    // Every notebook, with the contents of the open ones listed below each.
    public func rows(expanded: Set<UUID>) -> [TreeRow] {
        notebooks.flatMap { notebook -> [TreeRow] in
            let isExpanded = expanded.contains(notebook.id)
            let ref = TreeItemRef(kind: .notebook, id: notebook.id)
            let row = TreeRow(ref: ref, name: notebook.name, depth: 0, isExpanded: isExpanded, color: notebook.color)
            guard isExpanded else { return [row] }
            return [row] + rows(inNotebook: notebook.id, expanded: expanded, startingDepth: 1)
        }
    }

    // A notebook's sections in the order they appear, however deeply they're nested.
    public func sections(inNotebook notebookId: UUID) -> [TreeRow] {
        rows(inNotebook: notebookId, expanded: Set(groups.map(\.id))).filter { $0.ref.kind == .section }
    }
}

struct TreeItem {
    var ref: TreeItemRef
    var name: String
    var sortOrder: Double
    var color: ItemColor?
}
