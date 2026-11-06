// How text looks: the font list, and turning a saved style into what Apple's text system draws.
//
// The text system only understands fonts, colors and paragraph settings. It can't tell you
// afterward that text is "backwards", so each stretch of text also carries our own attributes
// (StyleBox and BlockBox below). Those are the truth, and the drawing attributes are worked
// out from them.

import CoreText
import JournalCore

#if canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#else
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#endif

extension NSAttributedString.Key {
    static let journalStyle = NSAttributedString.Key("journal.style")
    static let journalBlock = NSAttributedString.Key("journal.block")
}

// Wraps a TextStyle in an object, because attributes are compared with isEqual when the text
// system merges neighboring runs.
final class StyleBox: NSObject {
    let style: TextStyle

    init(_ style: TextStyle) {
        self.style = style
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? StyleBox)?.style == style
    }

    override var hash: Int { style.hashValue }
}

// A paragraph's block settings. `number` is the position in a numbered list. It's recalculated
// after edits and never saved.
struct BlockInfo: Equatable {
    var kind = BlockKind.paragraph
    var level = 0
    var isChecked = false
    var number = 0
    // What a list item's text is, like code. See Block.textKind.
    var textKind = BlockKind.paragraph

    // What the text looks like, whether or not it's in a list.
    var contentKind: BlockKind { kind.isList ? textKind : kind }
}

final class BlockBox: NSObject {
    let info: BlockInfo

    init(_ info: BlockInfo) {
        self.info = info
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? BlockBox)?.info == info
    }

    override var hash: Int { info.number &+ info.level &* 31 &+ info.kind.hashValue }
}

public struct FontChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String { id }
}

public enum FontCatalog {
    // These all ship with both macOS and iOS, so a page looks the same on both devices.
    public static let choices: [FontChoice] = [
        "New York", "Rounded", "Georgia", "Palatino", "Baskerville", "Times New Roman",
        "Avenir Next", "Helvetica Neue", "Menlo", "Courier New", "Noteworthy", "Snell Roundhand",
    ].map(FontChoice.init(id:))

    static func isAvailable(_ name: String) -> Bool {
        choices.contains { $0.id == name }
    }

    static func baseFont(named name: String?, size: CGFloat) -> PlatformFont {
        let system = PlatformFont.systemFont(ofSize: size)
        switch name {
        case nil:
            return system
        case "New York":
            return designed(.serif, from: system, size: size)
        case "Rounded":
            return designed(.rounded, from: system, size: size)
        case let name?:
            return PlatformFont(name: name, size: size) ?? system
        }
    }

    #if canImport(UIKit)
    private static func designed(_ design: UIFontDescriptor.SystemDesign, from font: UIFont, size: CGFloat) -> UIFont {
        font.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? font
    }
    #else
    private static func designed(_ design: NSFontDescriptor.SystemDesign, from font: NSFont, size: CGFloat) -> NSFont {
        font.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }
    #endif
}

enum EditorStyle {
    private static let slantAmount: CGFloat = 0.25

    static var bodySize: CGFloat {
        #if canImport(UIKit)
        17
        #else
        15
        #endif
    }

    static func defaultSize(for kind: BlockKind) -> CGFloat {
        switch kind {
        case .heading1: bodySize * 1.75
        case .heading2: bodySize * 1.4
        case .heading3: bodySize * 1.15
        case .code: bodySize - 1
        default: bodySize
        }
    }

    static func displaySize(style: TextStyle, kind: BlockKind) -> CGFloat {
        style.size.map { CGFloat($0) } ?? defaultSize(for: kind)
    }

    static func font(style: TextStyle, kind: BlockKind) -> PlatformFont {
        let isHeading = kind == .heading1 || kind == .heading2 || kind == .heading3
        let size = displaySize(style: style, kind: kind)
        let name = style.font ?? (kind == .code ? "Menlo" : nil)
        var font = FontCatalog.baseFont(named: name, size: size) as CTFont

        if style.bold || isHeading {
            font = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .boldTrait, .boldTrait) ?? font
        }

        switch style.slant {
        case .none:
            break
        case .italic:
            if let italic = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .italicTrait, .italicTrait) {
                font = italic
            } else {
                // Some fonts have no italic version, so lean the letters instead.
                font = skewed(font, by: slantAmount, size: size)
            }
        case .backwards:
            font = skewed(font, by: -slantAmount, size: size)
        }
        return font as PlatformFont
    }

    // A negative `.obliqueness` attribute stays upright, so the lean is built into the font.
    private static func skewed(_ font: CTFont, by amount: CGFloat, size: CGFloat) -> CTFont {
        var matrix = CGAffineTransform(a: 1, b: 0, c: amount, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font, size, &matrix, nil)
    }

    static var textColor: PlatformColor {
        #if canImport(UIKit)
        .label
        #else
        .labelColor
        #endif
    }

    static var secondaryColor: PlatformColor {
        #if canImport(UIKit)
        .secondaryLabel
        #else
        .secondaryLabelColor
        #endif
    }

    // Where a list item's content starts. The space to its left holds the bullet or number.
    static func listIndent(for block: BlockInfo) -> CGFloat {
        block.kind.isList ? 28 + CGFloat(block.level) * 24 : 0
    }

    // What's drawn to the left of a list item. Bullets change shape as they nest, and never use a
    // dash, so a bullet can't be mistaken for an item in a dash list. FE0E asks for the plain text
    // square, because the iPhone otherwise draws ▪ as a large emoji.
    static func marker(for block: BlockInfo) -> String {
        switch block.kind {
        case .numbered: "\(block.number)."
        case .dash: "–"
        default: ["•", "◦", "▪\u{FE0E}"][block.level % 3]
        }
    }

    // Where a paragraph's text starts. Quotes and code sit further in, inside their bar or box.
    static func headIndent(for block: BlockInfo) -> CGFloat {
        let content: CGFloat = switch block.contentKind {
        case .quote: 16
        case .code: 10
        default: 0
        }
        return listIndent(for: block) + content
    }

    static func paragraphStyle(for block: BlockInfo) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let indent = headIndent(for: block)
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        switch block.contentKind {
        case .heading1: style.paragraphSpacingBefore = 18; style.paragraphSpacing = 6
        case .heading2: style.paragraphSpacingBefore = 14; style.paragraphSpacing = 4
        case .heading3: style.paragraphSpacingBefore = 10; style.paragraphSpacing = 3
        // Code lines touch, so they read as one box. Code in a list is one box per item.
        case .code: style.tailIndent = -10; style.paragraphSpacing = block.kind.isList ? 3 : 0
        case .table: style.paragraphSpacingBefore = 8; style.paragraphSpacing = 8
        case .paragraph: style.paragraphSpacing = block.kind.isList ? 3 : 6
        default: style.paragraphSpacing = 6
        }
        return style
    }

    static func attributes(style: TextStyle, block: BlockInfo) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(style: style, kind: block.contentKind),
            .foregroundColor: block.kind == .checklist && block.isChecked ? secondaryColor : textColor,
            .paragraphStyle: paragraphStyle(for: block),
            .journalStyle: StyleBox(style),
            .journalBlock: BlockBox(block),
        ]
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = style.link, let url = URL(string: link) {
            attributes[.link] = url
        }
        return attributes
    }
}

public enum LinkPolicy {
    // Accepts what people type, like "example.com", and only allows web and email links.
    public static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains(":") ? trimmed : "https://" + trimmed
        guard let scheme = URL(string: withScheme)?.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return withScheme
    }
}
