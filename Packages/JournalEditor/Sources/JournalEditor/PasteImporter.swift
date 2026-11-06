// Turns copied content from other apps into the page format.
//
// Pasted text arrives with its own fonts and sizes, usually as HTML or RTF. This keeps what the
// content means (bold, lists, headings, tables, links) and drops what would clash with the page,
// like fonts the app doesn't offer.

import CoreText
import JournalCore

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// What was on the clipboard. Own format first, since it loses nothing.
struct ClipboardContents {
    var journal: Data?
    var html: Data?
    var rtf: Data?
    var text: String?
}

enum PasteImporter {
    static func document(from clipboard: ClipboardContents) -> PageDocument? {
        if let journal = clipboard.journal, let document = try? PageDocument.decoded(from: journal) {
            return document
        }
        if let html = clipboard.html, let text = String(data: html, encoding: .utf8) {
            let document = document(fromHTML: text)
            if !document.blocks.isEmpty { return document }
        }
        if let rtf = clipboard.rtf,
           let parsed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            let document = PageDocument(blocks: blocks(from: [parsed]))
            if !document.blocks.isEmpty { return document }
        }
        if let text = clipboard.text, !text.isEmpty {
            return document(fromPlainText: text)
        }
        return nil
    }

    static func document(fromPlainText text: String) -> PageDocument {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        return PageDocument(blocks: lines.map { Block(runs: $0.isEmpty ? [] : [TextRun($0)]) })
    }

    // MARK: HTML

    static func document(fromHTML html: String) -> PageDocument {
        let clean = sanitized(html)

        // Apple's HTML reader doesn't keep tables on iPhone, so tables are pulled out here and
        // the HTML around them goes through the reader.
        var pieces: [Piece] = []
        let string = clean as NSString
        var cursor = 0
        for match in matches(of: "<table\\b.*?</table\\s*>", in: clean) {
            pieces.append(.html(string.substring(with: NSRange(location: cursor, length: match.location - cursor))))
            pieces.append(.table(table(fromHTML: string.substring(with: match))))
            cursor = NSMaxRange(match)
        }
        pieces.append(.html(string.substring(from: cursor)))

        let parsed = pieces.map { piece -> ParsedPiece in
            switch piece {
            case .html(let text): return .text(attributedString(fromHTML: text))
            case .table(let table): return .table(table)
            }
        }

        // Sizes are judged against the whole paste's most common size.
        let baseSize = commonSize(in: parsed.compactMap { if case .text(let text) = $0 { return text } else { return nil } })
        var blocks: [Block] = []
        for piece in parsed {
            switch piece {
            case .text(let text): blocks += self.blocks(from: text, baseSize: baseSize)
            case .table(let table) where !table.rows.isEmpty: blocks.append(Block(kind: .table, table: table))
            case .table: break
            }
        }
        return PageDocument(blocks: trimmed(blocks))
    }

    private enum Piece {
        case html(String)
        case table(TableData)
    }

    private enum ParsedPiece {
        case text(NSAttributedString)
        case table(TableData)
    }

    // Anything that could load from the internet is removed first. The HTML reader would fetch
    // it otherwise, which a private journal shouldn't do just because something was pasted.
    private static func sanitized(_ html: String) -> String {
        var result = html
        let removals = [
            "<(script|style|svg|frameset|applet)\\b.*?</\\1\\s*>",
            "<!--.*?-->",
            "<(img|link|iframe|frame|object|embed|video|audio|source|track|meta|base|input)\\b[^>]*>",
        ]
        for pattern in removals {
            result = replacing(pattern, with: "", in: result)
        }
        // These appear inside tags. Text that merely says "url(...)" is left alone.
        for pattern in ["(<[^>]*?)url\\s*\\([^)]*\\)", "(<[^>]*?)\\bbackground\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)"] {
            var previous: String
            repeat {
                previous = result
                result = replacing(pattern, with: "$1", in: result)
            } while result != previous
        }
        return result
    }

    private static func replacing(_ pattern: String, with template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    private static func matches(of pattern: String, in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    private static func table(fromHTML html: String) -> TableData {
        let string = html as NSString
        var rows: [[String]] = []
        for rowRange in matches(of: "<tr\\b.*?</tr\\s*>", in: html) {
            let row = string.substring(with: rowRange)
            let cells = matches(of: "<t[dh]\\b.*?</t[dh]\\s*>", in: row).map { plainText(fromHTML: (row as NSString).substring(with: $0)) }
            if !cells.isEmpty { rows.append(cells) }
        }
        let width = rows.map(\.count).max() ?? 0
        return TableData(rows: rows.map { $0 + Array(repeating: "", count: width - $0.count) })
    }

    private static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: "</(p|div)\\s*>|<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func attributedString(fromHTML html: String) -> NSAttributedString {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return NSAttributedString() }
        return (try? NSAttributedString(
            data: Data(html.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )) ?? NSAttributedString()
    }

    // MARK: Attributed text to blocks

    private static func blocks(from pieces: [NSAttributedString]) -> [Block] {
        let baseSize = commonSize(in: pieces)
        return trimmed(pieces.flatMap { blocks(from: $0, baseSize: baseSize) })
    }

    private static func trimmed(_ blocks: [Block]) -> [Block] {
        var result = blocks
        while let last = result.last, last.kind == .paragraph, last.plainText.isEmpty {
            result.removeLast()
        }
        while let first = result.first, first.kind == .paragraph, first.plainText.isEmpty {
            result.removeFirst()
        }
        return result
    }

    private static func commonSize(in pieces: [NSAttributedString]) -> CGFloat {
        var totals: [CGFloat: Int] = [:]
        for piece in pieces {
            piece.enumerateAttribute(.font, in: NSRange(location: 0, length: piece.length)) { value, range, _ in
                if let font = value as? PlatformFont {
                    totals[font.pointSize, default: 0] += range.length
                }
            }
        }
        return totals.max { $0.value < $1.value }?.key ?? 12
    }

    private static func blocks(from text: NSAttributedString, baseSize: CGFloat) -> [Block] {
        var blocks: [Block] = []
        var location = 0
        while location < text.length {
            let paragraph = EditorEngine.paragraphRange(text, at: location)
            blocks.append(block(from: text, paragraph: EditorEngine.contentRange(text, paragraph: paragraph), baseSize: baseSize))
            location = NSMaxRange(paragraph)
        }
        return blocks
    }

    private static func block(from text: NSAttributedString, paragraph content: NSRange, baseSize: CGFloat) -> Block {
        var block = Block()
        guard content.length > 0 else { return block }

        var range = content
        if let style = text.attribute(.paragraphStyle, at: content.location, effectiveRange: nil) as? NSParagraphStyle,
           let list = style.textLists.last {
            block.kind = isDashed(list) ? .dash : isNumbered(list) ? .numbered : .bullet
            block.level = min(style.textLists.count - 1, 5)
            range = removingListMarker(from: text, range: content)
        }

        var isAllMonospace = true
        var isAllBold = true
        var largestRatio: CGFloat = 0
        text.enumerateAttributes(in: range) { attributes, run, _ in
            let runText = (text.string as NSString).substring(with: run)
                .replacingOccurrences(of: EditorEngine.attachmentCharacter, with: "")
            guard !runText.isEmpty else { return }
            let font = attributes[.font] as? PlatformFont
            let traits = font.map { CTFontGetSymbolicTraits($0 as CTFont) } ?? []
            let hasText = !runText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            var style = TextStyle()
            style.bold = traits.contains(.boldTrait)
            style.slant = traits.contains(.italicTrait) ? .italic : .none
            style.strikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            style.underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
            if let name = font?.familyName, FontCatalog.isAvailable(name) {
                style.font = name
            }
            if let link = linkText(attributes[.link]), let safe = LinkPolicy.normalized(link) {
                style.link = safe
                // Links already look like links, so the underline that HTML adds isn't kept.
                style.underline = false
            }
            if let font, hasText {
                let ratio = font.pointSize / baseSize
                largestRatio = max(largestRatio, ratio)
                isAllBold = isAllBold && style.bold
                isAllMonospace = isAllMonospace && traits.contains(.monoSpaceTrait)
                if abs(ratio - 1) > 0.05 {
                    style.size = Double((EditorStyle.bodySize * ratio).rounded())
                }
            }
            if let last = block.runs.last, last.style == style {
                block.runs[block.runs.count - 1].text += runText
            } else {
                block.runs.append(TextRun(runText, style: style))
            }
        }

        // Many apps write an empty line as a paragraph holding one non-breaking space. With no
        // visible text there's nothing to judge its kind by, so it's just an empty line.
        if block.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            block.runs = []
            return block
        }
        guard block.kind == .paragraph else {
            return block
        }
        if isAllMonospace {
            block.kind = .code
            clearFont(&block)
        } else if let heading = headingKind(ratio: largestRatio, isBold: isAllBold) {
            block.kind = heading
            clearFont(&block)
        }
        return block
    }

    private static func headingKind(ratio: CGFloat, isBold: Bool) -> BlockKind? {
        if ratio >= 1.6 { return .heading1 }
        if ratio >= 1.3 { return .heading2 }
        if ratio >= 1.1, isBold { return .heading3 }
        return nil
    }

    // Headings and code blocks have their own look, so their pasted fonts and sizes are dropped.
    private static func clearFont(_ block: inout Block) {
        for index in block.runs.indices {
            block.runs[index].style.size = nil
            block.runs[index].style.font = nil
            block.runs[index].style.bold = false
        }
        var merged: [TextRun] = []
        for run in block.runs {
            if let last = merged.last, last.style == run.style {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        block.runs = merged
    }

    // A web page's dash list arrives with the dash itself as the marker format, in braces on iPhone.
    private static func isDashed(_ list: NSTextList) -> Bool {
        let marker = list.markerFormat.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
        return list.markerFormat == .hyphen || ["-", "–", "—"].contains(marker)
    }

    private static func isNumbered(_ list: NSTextList) -> Bool {
        let bulletFormats: [NSTextList.MarkerFormat] = [.disc, .circle, .square, .box, .check, .diamond, .hyphen]
        return !bulletFormats.contains(list.markerFormat)
    }

    // Apple's HTML reader writes list markers into the text, as tab, marker, tab.
    private static func removingListMarker(from text: NSAttributedString, range: NSRange) -> NSRange {
        let string = (text.string as NSString).substring(with: range) as NSString
        let marker = string.range(of: "^\\t?[^\\t]{0,12}\\t", options: .regularExpression)
        guard marker.location == 0 else { return range }
        return NSRange(location: range.location + marker.length, length: range.length - marker.length)
    }

    private static func linkText(_ value: Any?) -> String? {
        switch value {
        case let url as URL: url.absoluteString
        case let text as String: text
        default: nil
        }
    }
}
