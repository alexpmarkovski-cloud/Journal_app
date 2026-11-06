// Text operations that don't depend on any screen: finding paragraphs, changing styles and
// keeping numbered lists correct. They work on plain attributed strings, so tests can run them
// without an editor on screen.

import Foundation
import JournalCore

enum EditorEngine {
    // An invisible character that holds a block's settings when a final paragraph is empty.
    // Settings live on characters, so a bullet with no text would otherwise have nowhere to
    // live. It's never saved.
    static let placeholder = "\u{200B}"
    // The character Apple's text system uses to mark an attachment, like a table.
    static let attachmentCharacter = "\u{FFFC}"
    // A new line that stays in the same paragraph. A list item's code uses it, so all of the
    // code sits beside one bullet or number.
    static let softLineBreak = "\u{2028}"
    static let softLineBreakCharacter: Character = "\u{2028}"

    static func paragraphRange(_ text: NSAttributedString, at location: Int) -> NSRange {
        (text.string as NSString).paragraphRange(for: NSRange(location: min(location, text.length), length: 0))
    }

    static func paragraphRanges(_ text: NSAttributedString, covering range: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = range.location
        repeat {
            let paragraph = paragraphRange(text, at: location)
            ranges.append(paragraph)
            location = NSMaxRange(paragraph)
        } while location < NSMaxRange(range) && location < text.length
        return ranges
    }

    // The paragraph without its line ending.
    static func contentRange(_ text: NSAttributedString, paragraph: NSRange) -> NSRange {
        var content = paragraph
        let string = text.string as NSString
        while content.length > 0, isLineEnd(string.character(at: NSMaxRange(content) - 1)) {
            content.length -= 1
        }
        return content
    }

    private static func isLineEnd(_ character: unichar) -> Bool {
        character == 10 || character == 13 || character == 0x2029
    }

    static func block(_ text: NSAttributedString, paragraph: NSRange) -> BlockInfo {
        guard paragraph.length > 0, paragraph.location < text.length else { return BlockInfo() }
        return blockAttribute(text, at: paragraph.location) ?? BlockInfo()
    }

    static func blockAttribute(_ text: NSAttributedString, at location: Int) -> BlockInfo? {
        (text.attribute(.journalBlock, at: location, effectiveRange: nil) as? BlockBox)?.info
    }

    static func style(_ text: NSAttributedString, at location: Int) -> TextStyle {
        (text.attribute(.journalStyle, at: location, effectiveRange: nil) as? StyleBox)?.style ?? TextStyle()
    }

    // True if the paragraph has no real text. It may still hold a placeholder.
    static func isBlank(_ text: NSAttributedString, paragraph: NSRange) -> Bool {
        let content = contentRange(text, paragraph: paragraph)
        return (text.string as NSString).substring(with: content).replacingOccurrences(of: placeholder, with: "").isEmpty
    }

    // Applies block settings to a paragraph. Fonts and indents depend on the block, so every
    // run is restyled.
    static func setBlock(_ block: BlockInfo, in text: NSMutableAttributedString, paragraph: NSRange) {
        guard paragraph.length > 0 else { return }
        text.enumerateAttribute(.journalStyle, in: paragraph) { value, run, _ in
            let style = (value as? StyleBox)?.style ?? TextStyle()
            replaceAttributes(in: text, range: run, style: style, block: block)
        }
    }

    // What typing a marker and a space at the start of a line turns it into, if anything. The
    // same marker in the middle of a sentence is just text.
    static func listShortcut(_ text: NSAttributedString, paragraph: NSRange, caret: Int) -> (kind: BlockKind, length: Int)? {
        let content = contentRange(text, paragraph: paragraph)
        guard caret > content.location, caret <= NSMaxRange(content) else { return nil }
        let typed = (text.string as NSString).substring(with: NSRange(location: content.location, length: caret - content.location))
        switch typed {
        case "*": return (.bullet, caret - content.location)
        case "-": return (.dash, caret - content.location)
        case "-0": return (.checklist, caret - content.location)
        case "1.": return (.numbered, caret - content.location)
        default: return nil
        }
    }

    // Being in a list and what the text looks like are separate choices, so changing one keeps
    // the other. `isOn` means the block already has this kind, so choosing it again removes it.
    static func changed(_ block: BlockInfo, to kind: BlockKind, isOn: Bool) -> BlockInfo {
        if kind.isList {
            if isOn { return BlockInfo(kind: block.contentKind) }
            var next = BlockInfo(kind: kind, textKind: block.contentKind)
            if block.kind.isList { next.level = block.level }
            return next
        }
        let target: BlockKind = isOn ? .paragraph : kind
        guard block.kind.isList else { return BlockInfo(kind: target) }
        var next = block
        next.textKind = target
        return next
    }

    static func changeStyle(in text: NSMutableAttributedString, range: NSRange, _ change: (inout TextStyle) -> Void) {
        guard range.length > 0 else { return }
        text.enumerateAttribute(.journalStyle, in: range) { value, run, _ in
            var style = (value as? StyleBox)?.style ?? TextStyle()
            change(&style)
            text.enumerateAttribute(.journalBlock, in: run) { blockValue, blockRun, _ in
                let block = (blockValue as? BlockBox)?.info ?? BlockInfo()
                replaceAttributes(in: text, range: blockRun, style: style, block: block)
            }
        }
    }

    // Keeps the attachment attribute, which is what makes a table a table.
    private static func replaceAttributes(in text: NSMutableAttributedString, range: NSRange, style: TextStyle, block: BlockInfo) {
        for key in [NSAttributedString.Key.strikethroughStyle, .underlineStyle, .link] {
            text.removeAttribute(key, range: range)
        }
        text.addAttributes(EditorStyle.attributes(style: style, block: block), range: range)
    }

    static func allStyles(in text: NSAttributedString, range: NSRange, satisfy test: (TextStyle) -> Bool) -> Bool {
        guard range.length > 0 else { return false }
        var result = true
        text.enumerateAttribute(.journalStyle, in: range) { value, _, stop in
            if !test((value as? StyleBox)?.style ?? TextStyle()) {
                result = false
                stop.pointee = true
            }
        }
        return result
    }

    static func wordRange(_ text: NSAttributedString, around location: Int) -> NSRange {
        let string = text.string as NSString
        func isWordCharacter(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(string.character(at: index)) else { return true }
            return !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && String(scalar) != placeholder && String(scalar) != attachmentCharacter
        }
        var start = location
        var end = location
        while start > 0, isWordCharacter(start - 1) { start -= 1 }
        while end < string.length, isWordCharacter(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    // All the neighboring text with the same link as the caret.
    static func linkRange(_ text: NSAttributedString, around location: Int) -> NSRange {
        func link(at index: Int) -> String? {
            index >= 0 && index < text.length ? style(text, at: index).link : nil
        }
        guard let current = link(at: location - 1) ?? link(at: location) else {
            return NSRange(location: location, length: 0)
        }
        var start = location
        var end = location
        while link(at: start - 1) == current { start -= 1 }
        while link(at: end) == current { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    // Numbers count up at each nesting level, and restart whenever the list is interrupted.
    static func renumber(_ text: NSMutableAttributedString) {
        var counters: [Int: Int] = [:]
        var location = 0
        while location < text.length {
            let paragraph = paragraphRange(text, at: location)
            var block = self.block(text, paragraph: paragraph)
            var number = 0
            if block.kind == .numbered {
                counters = counters.filter { $0.key <= block.level }
                number = (counters[block.level] ?? 0) + 1
                counters[block.level] = number
            } else if block.kind.isList {
                counters = counters.filter { $0.key <= block.level }
                counters[block.level] = nil
            } else {
                counters = [:]
            }
            if block.number != number {
                block.number = number
                text.addAttribute(.journalBlock, value: BlockBox(block), range: paragraph)
            }
            location = NSMaxRange(paragraph)
        }
    }

    // Puts a paragraph right after an edit. `caret` moves along with any characters added or
    // removed before it.
    //
    // Deleting a line break can leave a paragraph holding characters with different block
    // settings. Tables and dividers are split back onto their own lines. For anything else, the
    // first character decides for the whole paragraph.
    static func tidyParagraph(_ text: NSMutableAttributedString, paragraph: NSRange, caret: inout Int) {
        guard paragraph.length > 0 else { return }
        let added = separateTablesAndDividers(in: text, paragraph: paragraph, caret: &caret)
        let whole = NSRange(location: paragraph.location, length: paragraph.length + added)
        for part in paragraphRanges(text, covering: whole).reversed() {
            tidySingleParagraph(text, paragraph: part, caret: &caret)
        }
    }

    private static func separateTablesAndDividers(in text: NSMutableAttributedString, paragraph: NSRange, caret: inout Int) -> Int {
        let content = contentRange(text, paragraph: paragraph)
        guard content.length > 1 else { return 0 }
        var breaks: [Int] = []
        text.enumerateAttribute(.attachment, in: content) { value, range, _ in
            guard value is TableAttachment else { return }
            if range.location > content.location { breaks.append(range.location) }
            if NSMaxRange(range) < NSMaxRange(content) { breaks.append(NSMaxRange(range)) }
        }
        if blockAttribute(text, at: content.location)?.kind == .divider {
            breaks.append(content.location + 1)
        }
        for location in Set(breaks).sorted(by: >) {
            let block = blockAttribute(text, at: location - 1) ?? BlockInfo()
            let lineEnd = NSAttributedString(string: "\n", attributes: EditorStyle.attributes(style: TextStyle(), block: block))
            text.insert(lineEnd, at: location)
            if location <= caret { caret += 1 }
        }
        return breaks.count
    }

    private static func tidySingleParagraph(_ text: NSMutableAttributedString, paragraph: NSRange, caret: inout Int) {
        guard paragraph.length > 0 else { return }
        let block = self.block(text, paragraph: paragraph)
        var isUniform = true
        text.enumerateAttribute(.journalBlock, in: paragraph) { value, run, stop in
            if (value as? BlockBox)?.info != block, run.length != paragraph.length {
                isUniform = false
                stop.pointee = true
            }
        }
        if !isUniform {
            setBlock(block, in: text, paragraph: paragraph)
        }

        // The placeholder only holds a line open while it's empty.
        let content = contentRange(text, paragraph: paragraph)
        let string = (text.string as NSString).substring(with: content) as NSString
        let found = string.range(of: placeholder)
        guard block.kind != .divider, string.length > 1, found.location != NSNotFound else { return }
        let location = content.location + found.location
        text.deleteCharacters(in: NSRange(location: location, length: found.length))
        if location < caret { caret -= found.length }
    }
}
