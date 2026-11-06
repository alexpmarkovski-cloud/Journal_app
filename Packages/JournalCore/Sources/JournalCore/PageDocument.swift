// The saved form of a page body: a versioned list of blocks, where each block holds runs of
// styled text.
//
// This is the format your journal lives in for years, so it records meaning ("bold, Georgia,
// 18 point") and not how one screen happened to draw it. Fields that match the default are
// left out of the JSON, which keeps pages small.

import Foundation

public enum Slant: String, Codable, Sendable {
    case none, italic, backwards
}

public struct TextStyle: Codable, Hashable, Sendable {
    public var bold = false
    public var slant = Slant.none
    public var strikethrough = false
    public var underline = false
    // A name from the app's font list. Nil means the block's normal font.
    public var font: String?
    // In points. Nil means the block's normal size.
    public var size: Double?
    public var link: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case bold, slant, strikethrough, underline, font, size, link
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        slant = try container.decodeIfPresent(Slant.self, forKey: .slant) ?? .none
        strikethrough = try container.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        underline = try container.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        font = try container.decodeIfPresent(String.self, forKey: .font)
        size = try container.decodeIfPresent(Double.self, forKey: .size)
        link = try container.decodeIfPresent(String.self, forKey: .link)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if bold { try container.encode(bold, forKey: .bold) }
        if slant != .none { try container.encode(slant, forKey: .slant) }
        if strikethrough { try container.encode(strikethrough, forKey: .strikethrough) }
        if underline { try container.encode(underline, forKey: .underline) }
        try container.encodeIfPresent(font, forKey: .font)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(link, forKey: .link)
    }
}

public struct TextRun: Codable, Hashable, Sendable {
    public var text: String
    public var style = TextStyle()

    public init(_ text: String, style: TextStyle = TextStyle()) {
        self.text = text
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case text, style
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        style = try container.decodeIfPresent(TextStyle.self, forKey: .style) ?? TextStyle()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if style != TextStyle() { try container.encode(style, forKey: .style) }
    }
}

public enum BlockKind: String, Codable, Sendable {
    case paragraph, heading1, heading2, heading3, bullet, dash, numbered, checklist, quote, code, divider, table

    public var isList: Bool {
        self == .bullet || self == .dash || self == .numbered || self == .checklist
    }
}

public struct TableData: Codable, Hashable, Sendable {
    // Each row is a list of cells. Every row has the same number of cells.
    public var rows: [[String]]

    public init(rows: [[String]]) {
        self.rows = rows
    }

    public static func empty(rows: Int = 2, columns: Int = 2) -> TableData {
        TableData(rows: Array(repeating: Array(repeating: "", count: columns), count: rows))
    }

    public var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

public struct Block: Codable, Hashable, Sendable {
    public var kind: BlockKind
    public var runs: [TextRun]
    // How deeply a list item is nested. Zero is the outermost level.
    public var level: Int
    public var isChecked: Bool
    // What a list item's text is, like code. `kind` says it's in a list, and this says what's in
    // that item. Only list items use it, because other blocks are already what `kind` says.
    public var textKind: BlockKind
    public var table: TableData?

    public init(
        kind: BlockKind = .paragraph,
        runs: [TextRun] = [],
        level: Int = 0,
        isChecked: Bool = false,
        textKind: BlockKind = .paragraph,
        table: TableData? = nil
    ) {
        self.kind = kind
        self.runs = runs
        self.level = level
        self.isChecked = isChecked
        self.textKind = textKind
        self.table = table
    }

    // What the block's text looks like, whether or not it's in a list.
    public var contentKind: BlockKind {
        kind.isList ? textKind : kind
    }

    public var plainText: String {
        if let table {
            return table.rows.map { $0.joined(separator: " ") }.joined(separator: "\n")
        }
        return runs.map(\.text).joined()
    }

    private enum CodingKeys: String, CodingKey {
        case kind, runs, level, isChecked, textKind, table
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(BlockKind.self, forKey: .kind) ?? .paragraph
        runs = try container.decodeIfPresent([TextRun].self, forKey: .runs) ?? []
        level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 0
        isChecked = try container.decodeIfPresent(Bool.self, forKey: .isChecked) ?? false
        textKind = try container.decodeIfPresent(BlockKind.self, forKey: .textKind) ?? .paragraph
        table = try container.decodeIfPresent(TableData.self, forKey: .table)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if kind != .paragraph { try container.encode(kind, forKey: .kind) }
        if !runs.isEmpty { try container.encode(runs, forKey: .runs) }
        if level != 0 { try container.encode(level, forKey: .level) }
        if isChecked { try container.encode(isChecked, forKey: .isChecked) }
        if textKind != .paragraph { try container.encode(textKind, forKey: .textKind) }
        try container.encodeIfPresent(table, forKey: .table)
    }
}

public struct PageDocument: Codable, Hashable, Sendable {
    // Version 2 added `textKind`, and version 3 added dash lists. An older app can't keep either,
    // so it refuses these pages.
    public static let currentVersion = 3

    public var version = PageDocument.currentVersion
    public var blocks: [Block]

    public init(blocks: [Block] = []) {
        self.blocks = blocks
    }

    public var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    // Refuses a page saved by a newer version of the app. Opening it here could silently drop
    // whatever the newer version added, and then saving would erase it.
    public static func decoded(from data: Data) throws -> PageDocument {
        let document = try JSONDecoder().decode(PageDocument.self, from: data)
        guard document.version <= currentVersion else {
            throw JournalError.pageTooNew
        }
        return document
    }
}
