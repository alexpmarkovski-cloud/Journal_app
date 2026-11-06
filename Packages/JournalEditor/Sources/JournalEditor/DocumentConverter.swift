// Converts between the saved page format and the attributed text the editor works on.

import Foundation
import JournalCore

enum DocumentConverter {
    static func attributedString(from document: PageDocument) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            let isLast = index == document.blocks.count - 1
            let info = BlockInfo(kind: block.kind, level: block.level, isChecked: block.isChecked, textKind: block.textKind)
            let plain = EditorStyle.attributes(style: TextStyle(), block: info)

            switch block.kind {
            case .table:
                let attachment = TableAttachment(table: block.table ?? .empty())
                let string = NSMutableAttributedString(attachment: attachment)
                string.addAttributes(plain, range: NSRange(location: 0, length: string.length))
                result.append(string)
            case .divider:
                result.append(NSAttributedString(string: EditorEngine.placeholder, attributes: plain))
            default:
                for run in block.runs {
                    result.append(NSAttributedString(
                        string: run.text,
                        attributes: EditorStyle.attributes(style: run.style, block: info)
                    ))
                }
                if isLast, block.plainText.isEmpty, block.kind != .paragraph {
                    result.append(NSAttributedString(string: EditorEngine.placeholder, attributes: plain))
                }
            }
            if !isLast {
                result.append(NSAttributedString(string: "\n", attributes: plain))
            }
        }
        EditorEngine.renumber(result)
        return result
    }

    static func document(from text: NSAttributedString) -> PageDocument {
        var blocks: [Block] = []
        var location = 0
        while location < text.length {
            let paragraph = EditorEngine.paragraphRange(text, at: location)
            blocks += self.blocks(from: text, paragraph: paragraph)
            location = NSMaxRange(paragraph)
        }
        // Text ending in a line break has one more empty paragraph, where the caret can sit.
        // A line break inside a paragraph, like in a list item's code, doesn't count.
        if let last = text.string.last, last.isNewline, last != EditorEngine.softLineBreakCharacter {
            blocks.append(Block())
        }
        return PageDocument(blocks: blocks)
    }

    // Normally one paragraph makes one block. A table or divider sharing a line with text
    // becomes separate blocks, because saving must never drop any of the page.
    private static func blocks(from text: NSAttributedString, paragraph: NSRange) -> [Block] {
        let info = EditorEngine.block(text, paragraph: paragraph)
        let content = EditorEngine.contentRange(text, paragraph: paragraph)
        var blocks: [Block] = []
        var start = content.location

        if info.kind == .divider {
            blocks.append(Block(kind: .divider))
        }
        if content.length > 0 {
            text.enumerateAttribute(.attachment, in: content) { value, range, _ in
                guard let table = value as? TableAttachment else { return }
                if range.location > start {
                    let before = textBlock(from: text, range: NSRange(location: start, length: range.location - start), info: info)
                    if !before.runs.isEmpty { blocks.append(before) }
                }
                blocks.append(Block(kind: .table, table: table.table))
                start = NSMaxRange(range)
            }
        }
        let remaining = textBlock(from: text, range: NSRange(location: start, length: NSMaxRange(content) - start), info: info)
        if !remaining.runs.isEmpty || blocks.isEmpty {
            blocks.append(remaining)
        }
        return blocks
    }

    private static func textBlock(from text: NSAttributedString, range: NSRange, info: BlockInfo) -> Block {
        let holdsText = info.kind != .table && info.kind != .divider
        var block = holdsText ? Block(kind: info.kind, level: info.level, isChecked: info.isChecked, textKind: info.textKind) : Block()
        guard range.length > 0 else { return block }
        text.enumerateAttribute(.journalStyle, in: range) { value, run, _ in
            let runText = (text.string as NSString).substring(with: run)
                .replacingOccurrences(of: EditorEngine.placeholder, with: "")
                .replacingOccurrences(of: EditorEngine.attachmentCharacter, with: "")
            guard !runText.isEmpty else { return }
            let style = (value as? StyleBox)?.style ?? TextStyle()
            if let last = block.runs.last, last.style == style {
                block.runs[block.runs.count - 1].text += runText
            } else {
                block.runs.append(TextRun(runText, style: style))
            }
        }
        return block
    }
}
