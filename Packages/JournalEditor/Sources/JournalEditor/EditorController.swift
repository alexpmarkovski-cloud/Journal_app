// The editor's brain. The format bar calls its commands, and the Mac and iPhone text views report
// every keystroke to it, so the behavior lives here once and not in two platform versions.

import JournalCore
import Observation

#if canImport(UIKit)
import UIKit
typealias StorageEditActions = NSTextStorage.EditActions
#else
import AppKit
typealias StorageEditActions = NSTextStorageEditActions
#endif

// What the controller needs from a text view. RichTextView.swift provides it for each platform.
@MainActor
protocol EditorHost: AnyObject {
    var editorStorage: NSTextStorage { get }
    var editorSelection: NSRange { get set }
    var editorTypingAttributes: [NSAttributedString.Key: Any] { get set }
    var editorUndoManager: UndoManager? { get }
    var isComposingText: Bool { get }
    func prepareForEditorUndo()
    // Tables sit over the text, so they need moving whenever the text moves.
    func tablesChanged()
    // Opens the system's find bar for this page.
    func showFind()
}

// Autocorrect swaps a word in with fonts and colors but without our own settings, and clears the
// typing attributes as it does. If that word starts a list item, the whole item would fall out of
// the list. So the controller keeps this up to date with where the caret is, and any text that
// arrives with no settings gets these.
@MainActor
final class MissingSettingsGuard: NSObject, NSTextStorageDelegate {
    var block = BlockInfo()
    var style = TextStyle()

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: StorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), editedRange.length > 0 else { return }
        MainActor.assumeIsolated {
            textStorage.enumerateAttribute(.journalBlock, in: editedRange) { value, run, _ in
                guard value == nil else { return }
                textStorage.addAttributes(EditorStyle.attributes(style: style, block: block), range: run)
            }
        }
    }
}

// What the format bar shows as currently on.
public struct FormatState: Equatable {
    public var bold = false
    public var slant = Slant.none
    public var strikethrough = false
    public var underline = false
    public var font: String?
    public var size: Double = 0
    // A list item can also be code, so `blockKind` says it's in a list and `textKind` says what
    // its text is. For anything outside a list, the two are the same.
    public var blockKind = BlockKind.paragraph
    public var textKind = BlockKind.paragraph
    public var link: String?
    public var hasSelection = false
    public var isListItem: Bool { blockKind.isList }
}

@MainActor
@Observable
public final class EditorController {
    public private(set) var state = FormatState()
    // Called after any change to the page, so the app can save it.
    @ObservationIgnored public var onChange: () -> Void = {}

    @ObservationIgnored weak var host: EditorHost? {
        didSet { if let host { storage = host.editorStorage } }
    }
    // Kept even if the text view goes away first, so the final save can't lose typing.
    @ObservationIgnored private var storage: NSTextStorage?
    @ObservationIgnored private let initialDocument: PageDocument
    @ObservationIgnored private var needsRenumber = false
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var lastEdit: NSRange?
    @ObservationIgnored private var lastCaret: Int?
    @ObservationIgnored private let missingSettingsGuard = MissingSettingsGuard()

    public init(document: PageDocument) {
        initialDocument = document
    }

    // MARK: Connecting to a text view

    func attach(to host: EditorHost) {
        // If SwiftUI ever rebuilds the text view, it picks up what's been typed so far.
        let text = DocumentConverter.attributedString(from: document)
        self.host = host
        host.editorStorage.delegate = missingSettingsGuard
        host.editorStorage.setAttributedString(text)
        connectTables()
        host.editorSelection = NSRange(location: 0, length: 0)
        selectionDidChange()
    }

    public var document: PageDocument {
        guard let storage else { return initialDocument }
        return DocumentConverter.document(from: storage)
    }

    private func connectTables() {
        guard let storage = host?.editorStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let attachment = value as? TableAttachment else { return }
            attachment.model.onChange = { [weak self] in self?.onChange() }
            attachment.model.onSizeChange = { [weak self, weak attachment] in
                if let attachment { self?.relayOut(attachment) }
            }
        }
    }

    // Asks the text system to measure a table again after it gains or loses rows.
    private func relayOut(_ attachment: TableAttachment) {
        guard let storage = host?.editorStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as AnyObject === attachment {
                storage.beginEditing()
                storage.edited(.editedAttributes, range: range, changeInLength: 0)
                storage.endEditing()
                host?.tablesChanged()
                stop.pointee = true
            }
        }
    }

    // MARK: Undo

    // Runs a change that stays inside `range`, and makes it undoable by swapping the old text
    // back in. Undoing does the same thing in reverse, which is what makes redo work.
    private func perform(affecting range: NSRange, named name: String, _ change: (NSTextStorage) -> NSRange?) {
        guard let host else { return }
        let storage = host.editorStorage
        host.prepareForEditorUndo()
        let before = storage.attributedSubstring(from: range)
        let selectionBefore = host.editorSelection
        let lengthBefore = storage.length

        isApplying = true
        storage.beginEditing()
        let newSelection = change(storage)
        storage.endEditing()
        isApplying = false

        let after = NSRange(location: range.location, length: range.length + storage.length - lengthBefore)
        registerUndo(replacing: after, with: before, selection: selectionBefore, name: name)
        if let newSelection {
            host.editorSelection = newSelection
        }
        finishCommand()
    }

    private func registerUndo(replacing range: NSRange, with text: NSAttributedString, selection: NSRange, name: String) {
        guard let undoManager = host?.editorUndoManager else { return }
        undoManager.registerUndo(withTarget: self) { controller in
            controller.perform(affecting: range, named: name) { storage in
                storage.replaceCharacters(in: range, with: text)
                return selection
            }
        }
        undoManager.setActionName(name)
    }

    private func finishCommand() {
        guard let host else { return }
        isApplying = true
        EditorEngine.renumber(host.editorStorage)
        isApplying = false
        connectTables()
        host.tablesChanged()
        selectionDidChange()
        onChange()
    }

    // MARK: Reports from the text view

    // Decides what a keystroke does. Returning false means it was handled here.
    func shouldChangeText(in range: NSRange, replacement: String) -> Bool {
        guard let host, !isApplying else { return true }
        let storage = host.editorStorage
        let string = storage.string as NSString
        lastEdit = NSRange(location: range.location, length: (replacement as NSString).length)
        if replacement.contains(where: \.isNewline) || string.substring(with: range).contains(where: \.isNewline) {
            needsRenumber = true
        }
        let paragraph = EditorEngine.paragraphRange(storage, at: range.location)
        let block = EditorEngine.block(storage, paragraph: paragraph)
        missingSettingsGuard.block = block
        if range.length > 0 {
            missingSettingsGuard.style = EditorEngine.style(storage, at: range.location)
        }
        guard !host.isComposingText else { return true }

        if replacement == "\n", range.length == 0 {
            return handleReturn(at: range.location, paragraph: paragraph, block: block)
        }
        // Code is the exception, because a tab there is part of the code.
        if replacement == "\t", block.kind.isList, block.textKind != .code {
            changeIndent(by: 1)
            return false
        }
        if replacement == " ", range.length == 0, block.kind == .paragraph,
           let shortcut = EditorEngine.listShortcut(storage, paragraph: paragraph, caret: range.location) {
            startList(shortcut.kind, replacingFirst: shortcut.length, of: paragraph)
            return false
        }
        if replacement.isEmpty, range.length == 1, host.editorSelection.length == 0,
           host.editorSelection.location == NSMaxRange(range) {
            return handleBackspace(deleting: range)
        }
        if !replacement.isEmpty, block.kind == .divider || block.kind == .table {
            return typeAfterBlock(replacement, paragraph: paragraph)
        }
        return true
    }

    func textDidChange() {
        guard let host, !isApplying else { return }
        let storage = host.editorStorage

        if !host.isComposingText, let edit = lastEdit, edit.location <= storage.length {
            isApplying = true
            var caret = host.editorSelection.location
            let clamped = NSRange(location: edit.location, length: min(edit.length, storage.length - edit.location))
            for paragraph in EditorEngine.paragraphRanges(storage, covering: clamped).reversed() {
                EditorEngine.tidyParagraph(storage, paragraph: paragraph, caret: &caret)
            }
            if caret != host.editorSelection.location {
                host.editorSelection = NSRange(location: caret, length: 0)
            }
            isApplying = false
        }
        lastEdit = nil

        if needsRenumber {
            needsRenumber = false
            isApplying = true
            EditorEngine.renumber(storage)
            isApplying = false
        }
        host.tablesChanged()
        selectionDidChange()
        onChange()
    }

    // The caret must always type with its own paragraph's block settings. Left alone, the text
    // system copies them from the character before, which can belong to the paragraph above.
    func selectionDidChange() {
        guard let host, !isApplying, !host.isComposingText else { return }
        let storage = host.editorStorage
        let selection = host.editorSelection
        if selection.length == 0 {
            let paragraph = EditorEngine.paragraphRange(storage, at: selection.location)
            let block = EditorEngine.block(storage, paragraph: paragraph)
            let typingStyle = (host.editorTypingAttributes[.journalStyle] as? StyleBox)?.style
            var style = typingStyle ?? TextStyle()
            // When the caret moves, typing continues the style of the text next to it. When it
            // hasn't moved, keep the style, because Bold may have just been pressed. Autocorrect
            // clears the typing style, so that counts as moving.
            if selection.location != lastCaret || typingStyle == nil {
                style = styleNextToCaret(selection.location, paragraph: paragraph, storage: storage) ?? style
            }
            lastCaret = selection.location
            // A link only continues when the caret is inside it, not when it's at the end.
            if style.link != nil, !caretIsInsideLink(selection.location, storage: storage) {
                style.link = nil
            }
            host.editorTypingAttributes = EditorStyle.attributes(style: style, block: block)
            missingSettingsGuard.block = block
            missingSettingsGuard.style = style
        } else {
            lastCaret = nil
        }
        updateState()
    }

    private func styleNextToCaret(_ location: Int, paragraph: NSRange, storage: NSTextStorage) -> TextStyle? {
        let content = EditorEngine.contentRange(storage, paragraph: paragraph)
        if location > content.location, location <= NSMaxRange(content) {
            return EditorEngine.style(storage, at: location - 1)
        }
        if location < NSMaxRange(content) {
            return EditorEngine.style(storage, at: location)
        }
        return nil
    }

    private func caretIsInsideLink(_ location: Int, storage: NSTextStorage) -> Bool {
        guard location > 0, location < storage.length else { return false }
        let before = EditorEngine.style(storage, at: location - 1).link
        return before != nil && before == EditorEngine.style(storage, at: location).link
    }

    private func updateState() {
        guard let host else { return }
        let storage = host.editorStorage
        let selection = host.editorSelection
        let paragraph = EditorEngine.paragraphRange(storage, at: selection.location)
        let block = EditorEngine.block(storage, paragraph: paragraph)
        var new = FormatState()
        new.blockKind = block.kind
        new.textKind = block.contentKind
        new.hasSelection = selection.length > 0

        if selection.length == 0 {
            let style = (host.editorTypingAttributes[.journalStyle] as? StyleBox)?.style ?? TextStyle()
            new.bold = style.bold
            new.slant = style.slant
            new.strikethrough = style.strikethrough
            new.underline = style.underline
            new.font = style.font
            new.size = Double(EditorStyle.displaySize(style: style, kind: block.contentKind))
            new.link = selection.location > 0 && selection.location <= storage.length
                ? EditorEngine.style(storage, at: selection.location - 1).link : nil
        } else {
            let first = EditorEngine.style(storage, at: selection.location)
            new.bold = EditorEngine.allStyles(in: storage, range: selection) { $0.bold }
            new.slant = EditorEngine.allStyles(in: storage, range: selection) { $0.slant == first.slant } ? first.slant : .none
            new.strikethrough = EditorEngine.allStyles(in: storage, range: selection) { $0.strikethrough }
            new.underline = EditorEngine.allStyles(in: storage, range: selection) { $0.underline }
            new.font = first.font
            new.size = Double(EditorStyle.displaySize(style: first, kind: block.contentKind))
            new.link = first.link
        }
        if new != state {
            state = new
        }
    }

    // MARK: Return, backspace and typing rules

    private func handleReturn(at location: Int, paragraph: NSRange, block: BlockInfo) -> Bool {
        guard let host else { return true }
        let storage = host.editorStorage
        let content = EditorEngine.contentRange(storage, paragraph: paragraph)
        let isAtEnd = location >= NSMaxRange(content)

        switch block.kind {
        case .paragraph:
            return true

        case .bullet, .dash, .numbered, .checklist, .quote, .code:
            if EditorEngine.isBlank(storage, paragraph: paragraph) {
                // Return on an empty item ends the list, stepping out one level at a time.
                leaveBlock(paragraph: paragraph, block: block, named: "Change list")
                return false
            }
            // In a list item's code, Return adds a line of code. On an empty last line, it ends
            // the code and starts the next item.
            let endsCode = block.kind.isList && block.textKind == .code && isAtEnd && location > content.location
                && (storage.string as NSString).substring(with: NSRange(location: location - 1, length: 1)) == EditorEngine.softLineBreak
            if block.kind.isList, block.textKind == .code, !endsCode {
                perform(affecting: paragraph, named: "New line") { storage in
                    let style = (host.editorTypingAttributes[.journalStyle] as? StyleBox)?.style ?? TextStyle()
                    let line = NSAttributedString(string: EditorEngine.softLineBreak, attributes: EditorStyle.attributes(style: style, block: block))
                    storage.replaceCharacters(in: NSRange(location: location, length: 0), with: line)
                    return NSRange(location: location + line.length, length: 0)
                }
                return false
            }
            perform(affecting: paragraph, named: "New line") { storage in
                var next = block
                next.isChecked = false
                next.number = 0
                // A quote carries on, but a list of headings or code would be unusual to keep typing.
                if next.textKind != .quote { next.textKind = .paragraph }
                var location = location
                if endsCode {
                    location -= 1
                    storage.deleteCharacters(in: NSRange(location: location, length: 1))
                }
                let isLastParagraph = NSMaxRange(paragraph) - (endsCode ? 1 : 0) == storage.length
                let needsPlaceholder = isAtEnd && isLastParagraph
                let style = (host.editorTypingAttributes[.journalStyle] as? StyleBox)?.style ?? TextStyle()
                let attributes = EditorStyle.attributes(style: style, block: block)
                let insert = "\n" + (needsPlaceholder ? EditorEngine.placeholder : "")
                storage.replaceCharacters(in: NSRange(location: location, length: 0), with: NSAttributedString(string: insert, attributes: attributes))
                let caret = location + (insert as NSString).length
                EditorEngine.setBlock(next, in: storage, paragraph: EditorEngine.paragraphRange(storage, at: location + 1))
                return NSRange(location: caret, length: 0)
            }
            return false

        case .heading1, .heading2, .heading3, .divider, .table:
            guard isAtEnd else { return true }
            // After a heading or a table, the next line is ordinary text.
            perform(affecting: paragraph, named: "New line") { storage in
                let plain = EditorStyle.attributes(style: TextStyle(), block: BlockInfo())
                let insertAt = NSMaxRange(content)
                let keep = EditorStyle.attributes(style: TextStyle(), block: block)
                storage.replaceCharacters(in: NSRange(location: insertAt, length: 0), with: NSAttributedString(string: "\n", attributes: keep))
                // If a line ending followed, it now belongs to the new blank line.
                if NSMaxRange(paragraph) > NSMaxRange(content) {
                    storage.setAttributes(plain, range: NSRange(location: insertAt + 1, length: 1))
                }
                return NSRange(location: insertAt + 1, length: 0)
            }
            return false
        }
    }

    private func handleBackspace(deleting range: NSRange) -> Bool {
        guard let host else { return true }
        let storage = host.editorStorage
        let caret = host.editorSelection.location
        let paragraph = EditorEngine.paragraphRange(storage, at: caret)
        let block = EditorEngine.block(storage, paragraph: paragraph)
        let isHolder = (storage.string as NSString).substring(with: range) == EditorEngine.placeholder

        if isHolder, block.kind == .divider {
            perform(affecting: extendedBackOverLineEnd(paragraph), named: "Delete divider") { storage in
                let target = extendedBackOverLineEnd(paragraph)
                storage.deleteCharacters(in: target)
                return NSRange(location: target.location, length: 0)
            }
            return false
        }
        guard block.kind != .paragraph, block.kind != .table, block.kind != .divider,
              isHolder || caret == paragraph.location else { return true }
        leaveBlock(paragraph: paragraph, block: block, named: "Change list")
        return false
    }

    private func extendedBackOverLineEnd(_ paragraph: NSRange) -> NSRange {
        guard paragraph.location > 0, NSMaxRange(paragraph) == host?.editorStorage.length else { return paragraph }
        return NSRange(location: paragraph.location - 1, length: paragraph.length + 1)
    }

    // Typing a marker and a space starts a list. The marker is removed, and any text after it
    // stays, so this also turns an existing line into a list item.
    private func startList(_ kind: BlockKind, replacingFirst length: Int, of paragraph: NSRange) {
        perform(affecting: paragraph, named: "Start list") { storage in
            let block = BlockInfo(kind: kind)
            let marker = NSRange(location: paragraph.location, length: length)
            let caret = NSRange(location: paragraph.location, length: 0)
            // A last line with nothing else on it has no characters left to hold its settings.
            guard paragraph.length > length else {
                let holder = NSAttributedString(
                    string: EditorEngine.placeholder,
                    attributes: EditorStyle.attributes(style: TextStyle(), block: block)
                )
                storage.replaceCharacters(in: marker, with: holder)
                return NSRange(location: paragraph.location + holder.length, length: 0)
            }
            storage.deleteCharacters(in: marker)
            EditorEngine.setBlock(block, in: storage, paragraph: NSRange(location: paragraph.location, length: paragraph.length - length))
            return caret
        }
    }

    // A list item's code or heading goes back to text first, and stays in the list. After that, a
    // nested item moves out one level, and an outermost item becomes ordinary text.
    private func leaveBlock(paragraph: NSRange, block: BlockInfo, named name: String) {
        perform(affecting: paragraph, named: name) { storage in
            var next = block
            if block.kind.isList, block.textKind != .paragraph {
                next.textKind = .paragraph
            } else if block.kind.isList, block.level > 0 {
                next.level -= 1
            } else {
                next = BlockInfo()
            }
            if next.kind == .paragraph {
                let content = EditorEngine.contentRange(storage, paragraph: paragraph)
                if (storage.string as NSString).substring(with: content) == EditorEngine.placeholder {
                    storage.deleteCharacters(in: content)
                    let updated = NSRange(location: paragraph.location, length: paragraph.length - content.length)
                    EditorEngine.setBlock(next, in: storage, paragraph: updated)
                    return NSRange(location: paragraph.location, length: 0)
                }
            }
            EditorEngine.setBlock(next, in: storage, paragraph: paragraph)
            return nil
        }
    }

    // Tables and dividers don't hold text, so typing on one starts a new line after it.
    private func typeAfterBlock(_ text: String, paragraph: NSRange) -> Bool {
        guard let host else { return true }
        let storage = host.editorStorage
        let content = EditorEngine.contentRange(storage, paragraph: paragraph)
        perform(affecting: NSRange(location: NSMaxRange(content), length: 0), named: "Typing") { storage in
            let plain = EditorStyle.attributes(style: TextStyle(), block: BlockInfo())
            let insert = NSAttributedString(string: "\n" + text, attributes: plain)
            storage.replaceCharacters(in: NSRange(location: NSMaxRange(content), length: 0), with: insert)
            return NSRange(location: NSMaxRange(content) + insert.length, length: 0)
        }
        return false
    }

    // MARK: Text style commands

    public func toggleBold() {
        let target = !state.bold
        changeStyle(named: "Bold") { $0.bold = target }
    }

    public func toggleSlant(_ slant: Slant) {
        let target: Slant = state.slant == slant ? .none : slant
        changeStyle(named: "Slant") { $0.slant = target }
    }

    public func toggleStrikethrough() {
        let target = !state.strikethrough
        changeStyle(named: "Strikethrough") { $0.strikethrough = target }
    }

    public func toggleUnderline() {
        let target = !state.underline
        changeStyle(named: "Underline") { $0.underline = target }
    }

    public func setFont(_ name: String?) {
        changeStyle(named: "Font") { $0.font = name }
    }

    public func setSize(_ size: Double) {
        changeStyle(named: "Size") { $0.size = max(8, min(size, 96)) }
    }

    // With nothing selected, a link goes on the word under the caret. Returns false if there's
    // no text to link, or the address isn't allowed.
    public func setLink(_ text: String) -> Bool {
        guard let host, let link = LinkPolicy.normalized(text) else { return false }
        let selection = host.editorSelection
        let range = selection.length > 0 ? selection : EditorEngine.wordRange(host.editorStorage, around: selection.location)
        guard range.length > 0 else { return false }
        perform(affecting: range, named: "Link") { storage in
            EditorEngine.changeStyle(in: storage, range: range) { $0.link = link }
            return selection
        }
        return true
    }

    public func removeLink() {
        guard let host else { return }
        let selection = host.editorSelection
        let range = selection.length > 0 ? selection : EditorEngine.linkRange(host.editorStorage, around: selection.location)
        guard range.length > 0 else { return }
        perform(affecting: range, named: "Remove link") { storage in
            EditorEngine.changeStyle(in: storage, range: range) { $0.link = nil }
            return selection
        }
    }

    private func changeStyle(named name: String, _ change: @escaping (inout TextStyle) -> Void) {
        guard let host else { return }
        let selection = host.editorSelection
        if selection.length == 0 {
            // With nothing selected, the change applies to whatever is typed next.
            var style = (host.editorTypingAttributes[.journalStyle] as? StyleBox)?.style ?? TextStyle()
            change(&style)
            let paragraph = EditorEngine.paragraphRange(host.editorStorage, at: selection.location)
            let block = EditorEngine.block(host.editorStorage, paragraph: paragraph)
            host.editorTypingAttributes = EditorStyle.attributes(style: style, block: block)
            updateState()
            return
        }
        perform(affecting: selection, named: name) { storage in
            EditorEngine.changeStyle(in: storage, range: selection, change)
            return selection
        }
    }

    // MARK: Block commands

    // Choosing the block a paragraph already is turns that choice off. Lists and what the text
    // looks like are separate, so a numbered item can become code and keep its number.
    public func setBlockKind(_ kind: BlockKind) {
        guard let host else { return }
        let isOn = kind.isList ? state.blockKind == kind : state.textKind == kind
        let storage = host.editorStorage
        let selection = host.editorSelection
        let paragraphs = EditorEngine.paragraphRanges(storage, covering: selection)
        guard let first = paragraphs.first, let last = paragraphs.last else { return }
        let whole = NSUnionRange(first, last)

        perform(affecting: whole, named: "Change block") { storage in
            // An empty final line has no characters to hold its settings, so it gets a placeholder.
            let firstBlock = EditorEngine.changed(EditorEngine.block(storage, paragraph: first), to: kind, isOn: isOn)
            if first.length == 0, firstBlock.kind != .paragraph {
                let holder = NSAttributedString(
                    string: EditorEngine.placeholder,
                    attributes: EditorStyle.attributes(style: TextStyle(), block: firstBlock)
                )
                storage.replaceCharacters(in: NSRange(location: first.location, length: 0), with: holder)
                return NSRange(location: first.location + holder.length, length: 0)
            }
            for paragraph in paragraphs.reversed() {
                let current = EditorEngine.block(storage, paragraph: paragraph)
                guard current.kind != .table, current.kind != .divider else { continue }
                EditorEngine.setBlock(EditorEngine.changed(current, to: kind, isOn: isOn), in: storage, paragraph: paragraph)
            }
            // A placeholder isn't needed on ordinary text.
            if firstBlock.kind == .paragraph, paragraphs.count == 1,
               (storage.string as NSString).substring(with: EditorEngine.contentRange(storage, paragraph: first)) == EditorEngine.placeholder {
                storage.deleteCharacters(in: EditorEngine.contentRange(storage, paragraph: first))
                return NSRange(location: first.location, length: 0)
            }
            return selection
        }
    }

    public func indent() { changeIndent(by: 1) }

    public func outdent() { changeIndent(by: -1) }

    private func changeIndent(by amount: Int) {
        guard let host else { return }
        let storage = host.editorStorage
        let selection = host.editorSelection
        let paragraphs = EditorEngine.paragraphRanges(storage, covering: selection)
        guard let first = paragraphs.first, let last = paragraphs.last else { return }
        perform(affecting: NSUnionRange(first, last), named: "Change indent") { storage in
            for paragraph in paragraphs {
                var block = EditorEngine.block(storage, paragraph: paragraph)
                guard block.kind.isList else { continue }
                block.level = max(0, min(block.level + amount, 5))
                EditorEngine.setBlock(block, in: storage, paragraph: paragraph)
            }
            return selection
        }
    }

    func toggleCheck(atParagraphContaining location: Int) {
        guard let host else { return }
        let paragraph = EditorEngine.paragraphRange(host.editorStorage, at: location)
        var block = EditorEngine.block(host.editorStorage, paragraph: paragraph)
        guard block.kind == .checklist else { return }
        block.isChecked.toggle()
        let selection = host.editorSelection
        perform(affecting: paragraph, named: "Check item") { storage in
            EditorEngine.setBlock(block, in: storage, paragraph: paragraph)
            return selection
        }
    }

    public func insertTable() {
        insertBlock(Block(kind: .table, table: .empty(rows: 2, columns: 3)))
    }

    public func insertDivider() {
        insertBlock(Block(kind: .divider))
    }

    // Used to place a saved quote in the page.
    public func insertBlocks(_ blocks: [Block]) {
        guard !blocks.isEmpty else { return }
        insertBlocksOnOwnLines(blocks)
    }

    private func insertBlock(_ block: Block) {
        insertBlocksOnOwnLines([block])
    }

    // Blocks like tables always get their own line, with an empty line after to keep typing in.
    private func insertBlocksOnOwnLines(_ blocks: [Block]) {
        guard let host else { return }
        let storage = host.editorStorage
        let selection = host.editorSelection
        let paragraph = EditorEngine.paragraphRange(storage, at: selection.location)
        let content = EditorEngine.contentRange(storage, paragraph: paragraph)
        let isBlank = EditorEngine.isBlank(storage, paragraph: paragraph)
            && EditorEngine.block(storage, paragraph: paragraph).kind == .paragraph
        let target = isBlank ? content : NSRange(location: NSMaxRange(content), length: 0)
        let hasLineAfter = NSMaxRange(paragraph) > NSMaxRange(content)

        perform(affecting: target, named: "Insert") { storage in
            let inserted = NSMutableAttributedString()
            let plain = EditorStyle.attributes(style: TextStyle(), block: BlockInfo())
            if !isBlank {
                inserted.append(NSAttributedString(string: "\n", attributes: plain))
            }
            inserted.append(DocumentConverter.attributedString(from: PageDocument(blocks: blocks)))
            if !hasLineAfter {
                inserted.append(NSAttributedString(string: "\n", attributes: plain))
            }
            storage.replaceCharacters(in: target, with: inserted)
            return NSRange(location: target.location + inserted.length + (hasLineAfter ? 1 : 0), length: 0)
        }
    }

    // MARK: Pasting and links

    func paste(_ clipboard: ClipboardContents) {
        guard let host, let pasted = PasteImporter.document(from: clipboard) else { return }
        let selection = host.editorSelection
        let storage = host.editorStorage
        let isInline = pasted.blocks.count == 1 && pasted.blocks[0].kind == .paragraph

        perform(affecting: selection, named: "Paste") { storage in
            let text: NSMutableAttributedString = DocumentConverter.attributedString(from: pasted)
            if isInline {
                // A single line takes on the block it's pasted into.
                let paragraph = EditorEngine.paragraphRange(storage, at: selection.location)
                let block = EditorEngine.block(storage, paragraph: paragraph)
                EditorEngine.setBlock(block, in: text, paragraph: NSRange(location: 0, length: text.length))
            }
            storage.replaceCharacters(in: selection, with: text)
            return NSRange(location: selection.location + text.length, length: 0)
        }

        // Tidy the paragraphs around the paste, like removing a leftover placeholder.
        let affected = NSRange(location: selection.location, length: min(host.editorSelection.location - selection.location, storage.length - selection.location))
        isApplying = true
        var caret = host.editorSelection.location
        for paragraph in EditorEngine.paragraphRanges(storage, covering: affected).reversed() {
            EditorEngine.tidyParagraph(storage, paragraph: paragraph, caret: &caret)
        }
        host.editorSelection = NSRange(location: caret, length: 0)
        isApplying = false
        finishCommand()
    }

    public func showFind() {
        host?.showFind()
    }

    // The selected words without their formatting, or nil if nothing is selected.
    public func selectedPlainText() -> String? {
        guard let host, host.editorSelection.length > 0 else { return nil }
        let text = host.editorStorage.attributedSubstring(from: host.editorSelection)
        let plain = DocumentConverter.document(from: text).plainText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : plain
    }

    // The selected part of the page in the app's own format, for pasting back in without loss.
    func selectedDocumentData() -> Data? {
        guard let host, host.editorSelection.length > 0 else { return nil }
        let text = host.editorStorage.attributedSubstring(from: host.editorSelection)
        return try? DocumentConverter.document(from: text).encoded()
    }

    public func linkURLForOpening() -> URL? {
        state.link.flatMap(LinkPolicy.normalized).flatMap(URL.init(string:))
    }
}
