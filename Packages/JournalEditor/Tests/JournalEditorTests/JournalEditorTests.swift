import CoreText
import Foundation
import JournalCore
import Testing
@testable import JournalEditor

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

private func styled(_ text: String, _ change: (inout TextStyle) -> Void) -> TextRun {
    var style = TextStyle()
    change(&style)
    return TextRun(text, style: style)
}

// A stand-in for the text view, so editor behavior can be tested without a screen.
@MainActor
private final class FakeHost: EditorHost {
    let editorStorage = NSTextStorage()
    var editorSelection = NSRange(location: 0, length: 0)
    var editorTypingAttributes: [NSAttributedString.Key: Any] = [:]
    let undo = UndoManager()
    var editorUndoManager: UndoManager? { undo }
    var isComposingText = false

    init() {
        undo.groupsByEvent = false
    }

    func tablesChanged() {}
    func showFind() { findRequests += 1 }
    var findRequests = 0

    // Normally the app's event loop starts and ends undo groups. Here each command gets its own.
    func prepareForEditorUndo() {
        guard !undo.isUndoing, !undo.isRedoing else { return }
        if undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.beginUndoGrouping()
    }

    func undoLast() {
        if undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.undo()
    }

    // Does what a real text view does when a key is pressed.
    func type(_ text: String, with controller: EditorController) {
        let range = editorSelection
        guard controller.shouldChangeText(in: range, replacement: text) else { return }
        editorStorage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: editorTypingAttributes))
        editorSelection = NSRange(location: range.location + (text as NSString).length, length: 0)
        controller.textDidChange()
    }

    func backspace(with controller: EditorController) {
        let range = NSRange(location: editorSelection.location - 1, length: 1)
        guard controller.shouldChangeText(in: range, replacement: "") else { return }
        editorStorage.replaceCharacters(in: range, with: "")
        editorSelection = NSRange(location: range.location, length: 0)
        controller.textDidChange()
    }
}

@MainActor
private func makeEditor(_ blocks: [Block] = [Block()]) -> (EditorController, FakeHost) {
    let controller = EditorController(document: PageDocument(blocks: blocks))
    let host = FakeHost()
    controller.attach(to: host)
    return (controller, host)
}

@Suite("Converting pages")
struct ConversionTests {
    @Test func everyStyleAndBlockSurvivesARoundTrip() {
        let document = PageDocument(blocks: [
            Block(kind: .heading1, runs: [TextRun("Title")]),
            Block(runs: [
                TextRun("plain "),
                styled("bold ") { $0.bold = true },
                styled("italic ") { $0.slant = .italic },
                styled("backwards ") { $0.slant = .backwards },
                styled("struck ") { $0.strikethrough = true },
                styled("under ") { $0.underline = true },
                styled("georgia ") { $0.font = "Georgia" },
                styled("big ") { $0.size = 28 },
                styled("link") { $0.link = "https://example.com" },
            ]),
            Block(kind: .bullet, runs: [TextRun("one")]),
            Block(kind: .bullet, runs: [TextRun("nested")], level: 1),
            Block(kind: .numbered, runs: [TextRun("first")]),
            Block(kind: .checklist, runs: [TextRun("done")], isChecked: true),
            Block(kind: .quote, runs: [TextRun("quoted")]),
            Block(kind: .code, runs: [TextRun("let x = 1")]),
            Block(kind: .divider),
            Block(kind: .table, table: TableData(rows: [["a", "b"], ["c", "d"]])),
            Block(runs: [TextRun("after")]),
        ])
        let text = DocumentConverter.attributedString(from: document)
        #expect(DocumentConverter.document(from: text) == document)
    }

    @Test func aPageEndingInAnEmptyLineKeepsIt() {
        let document = PageDocument(blocks: [Block(runs: [TextRun("text")]), Block()])
        let text = DocumentConverter.attributedString(from: document)
        #expect(DocumentConverter.document(from: text) == document)
    }

    @Test func aFinalEmptyListItemKeepsItsKind() {
        let document = PageDocument(blocks: [Block(kind: .bullet)])
        let text = DocumentConverter.attributedString(from: document)
        #expect(text.string == EditorEngine.placeholder)
        #expect(DocumentConverter.document(from: text) == document)
    }

    @Test func numbersCountUpAndRestart() {
        let text = DocumentConverter.attributedString(from: PageDocument(blocks: [
            Block(kind: .numbered, runs: [TextRun("a")]),
            Block(kind: .numbered, runs: [TextRun("b")]),
            Block(kind: .numbered, runs: [TextRun("nested")], level: 1),
            Block(kind: .numbered, runs: [TextRun("c")]),
            Block(runs: [TextRun("break")]),
            Block(kind: .numbered, runs: [TextRun("d")]),
        ]))
        var numbers: [Int] = []
        var location = 0
        while location < text.length {
            let paragraph = EditorEngine.paragraphRange(text, at: location)
            numbers.append(EditorEngine.block(text, paragraph: paragraph).number)
            location = NSMaxRange(paragraph)
        }
        #expect(numbers == [1, 2, 1, 3, 0, 1])
    }
}

@Suite("Fonts")
struct FontTests {
    @Test func backwardsItalicLeansLeftAndItalicLeansRight() {
        var style = TextStyle()
        style.slant = .backwards
        let backwards = EditorStyle.font(style: style, kind: .paragraph) as CTFont
        #expect(CTFontGetMatrix(backwards).c < 0)

        // Georgia has a true italic. A font's own italic has a positive italic angle or matrix.
        style.slant = .italic
        style.font = "Georgia"
        let italic = EditorStyle.font(style: style, kind: .paragraph) as CTFont
        #expect(CTFontGetSymbolicTraits(italic).contains(.italicTrait))
    }

    @Test func everyListedFontExists() {
        for choice in FontCatalog.choices where choice.id != "New York" && choice.id != "Rounded" {
            #expect(PlatformFont(name: choice.id, size: 12) != nil, "\(choice.id) is missing")
        }
    }

    @Test func headingsAreBoldAndBigger() {
        let heading = EditorStyle.font(style: TextStyle(), kind: .heading1) as CTFont
        #expect(CTFontGetSymbolicTraits(heading).contains(.boldTrait))
        #expect(CTFontGetSize(heading) > EditorStyle.bodySize)
    }
}

@Suite("Links")
struct LinkTests {
    @Test func webAndEmailLinksAreAllowed() {
        #expect(LinkPolicy.normalized("example.com") == "https://example.com")
        #expect(LinkPolicy.normalized("http://example.com/a") == "http://example.com/a")
        #expect(LinkPolicy.normalized("mailto:me@example.com") == "mailto:me@example.com")
    }

    @Test func otherLinksAreRefused() {
        #expect(LinkPolicy.normalized("javascript:alert(1)") == nil)
        #expect(LinkPolicy.normalized("file:///etc/passwd") == nil)
        #expect(LinkPolicy.normalized("") == nil)
        #expect(LinkPolicy.normalized("two words") == nil)
    }
}

@Suite("Editing")
@MainActor
struct EditingTests {
    @Test func stylingASelectionAndUndoingIt() {
        let (controller, host) = makeEditor([Block(runs: [TextRun("hello world")])])
        host.editorSelection = NSRange(location: 0, length: 5)
        controller.selectionDidChange()

        controller.toggleSlant(.backwards)
        #expect(controller.document.blocks[0].runs == [
            styled("hello") { $0.slant = .backwards },
            TextRun(" world"),
        ])
        #expect(controller.state.slant == .backwards)

        host.undoLast()
        #expect(controller.document.blocks[0].runs == [TextRun("hello world")])
        host.undo.redo()
        #expect(controller.document.blocks[0].runs.first?.style.slant == .backwards)
    }

    @Test func aStyleWithNoSelectionAppliesToTheNextTyping() {
        let (controller, host) = makeEditor()
        controller.toggleBold()
        #expect(controller.state.bold)
        host.type("bold", with: controller)
        #expect(controller.document.blocks[0].runs == [styled("bold") { $0.bold = true }])
    }

    @Test func movingTheCaretPicksUpTheStyleOfNearbyText() {
        let (controller, host) = makeEditor([Block(runs: [
            TextRun("plain "),
            styled("lean") { $0.slant = .backwards },
        ])])
        host.editorSelection = NSRange(location: 10, length: 0)
        controller.selectionDidChange()
        #expect(controller.state.slant == .backwards)
        host.type("!", with: controller)
        #expect(controller.document.blocks[0].runs.last == styled("lean!") { $0.slant = .backwards })

        host.editorSelection = NSRange(location: 2, length: 0)
        controller.selectionDidChange()
        #expect(controller.state.slant == .none)
    }

    @Test func aLinkWithNoSelectionGoesOnTheWordAndComesOffAgain() {
        let (controller, host) = makeEditor([Block(runs: [TextRun("read this now")])])
        host.editorSelection = NSRange(location: 7, length: 0)
        controller.selectionDidChange()

        #expect(controller.setLink("example.com"))
        #expect(controller.document.blocks[0].runs == [
            TextRun("read "),
            styled("this") { $0.link = "https://example.com" },
            TextRun(" now"),
        ])
        controller.selectionDidChange()
        #expect(controller.state.link == "https://example.com")

        controller.removeLink()
        #expect(controller.document.blocks[0].runs == [TextRun("read this now")])
    }

    @Test func aLinkNeedsTextAndASafeAddress() {
        let (controller, host) = makeEditor([Block(runs: [TextRun("word")])])
        host.editorSelection = NSRange(location: 2, length: 0)
        #expect(!controller.setLink("javascript:alert(1)"))

        let (empty, _) = makeEditor([Block()])
        #expect(!empty.setLink("example.com"))
        _ = host
    }

    @Test func returnContinuesAListAndEndsItWhenEmpty() {
        let (controller, host) = makeEditor([Block(kind: .bullet, runs: [TextRun("one")])])
        host.editorSelection = NSRange(location: 3, length: 0)
        controller.selectionDidChange()

        host.type("\n", with: controller)
        host.type("two", with: controller)
        #expect(controller.document.blocks.map(\.plainText) == ["one", "two"])
        #expect(controller.document.blocks.map(\.kind) == [.bullet, .bullet])

        host.type("\n", with: controller)
        #expect(controller.document.blocks.map(\.kind) == [.bullet, .bullet, .bullet])
        host.type("\n", with: controller)
        #expect(controller.document.blocks.map(\.kind) == [.bullet, .bullet, .paragraph])
        #expect(controller.document.blocks.last?.plainText == "")
    }

    @Test func typingInAnEmptyListItemRemovesTheHiddenCharacter() {
        let (controller, host) = makeEditor([Block(kind: .bullet)])
        host.editorSelection = NSRange(location: 1, length: 0)
        controller.selectionDidChange()
        host.type("a", with: controller)
        #expect(host.editorStorage.string == "a")
        #expect(host.editorSelection.location == 1)
        #expect(controller.document.blocks == [Block(kind: .bullet, runs: [TextRun("a")])])
    }

    @Test func backspaceAtTheStartOfAListItemMakesItText() {
        let (controller, host) = makeEditor([
            Block(runs: [TextRun("top")]),
            Block(kind: .bullet, runs: [TextRun("one")]),
        ])
        host.editorSelection = NSRange(location: 4, length: 0)
        controller.selectionDidChange()
        host.backspace(with: controller)
        #expect(controller.document.blocks.map(\.kind) == [.paragraph, .paragraph])
        #expect(controller.document.blocks.map(\.plainText) == ["top", "one"])
    }

    @Test func returnAfterAHeadingGoesBackToText() {
        let (controller, host) = makeEditor([Block(kind: .heading1, runs: [TextRun("Title")])])
        host.editorSelection = NSRange(location: 5, length: 0)
        controller.selectionDidChange()
        host.type("\n", with: controller)
        host.type("body", with: controller)
        #expect(controller.document.blocks.map(\.kind) == [.heading1, .paragraph])
        #expect(controller.document.blocks.map(\.plainText) == ["Title", "body"])
    }

    @Test func returnInsideACodeBlockStaysCode() {
        let (controller, host) = makeEditor([Block(kind: .code, runs: [TextRun("a")])])
        host.editorSelection = NSRange(location: 1, length: 0)
        controller.selectionDidChange()
        host.type("\n", with: controller)
        host.type("b", with: controller)
        #expect(controller.document.blocks.map(\.kind) == [.code, .code])
    }

    @Test func indentingNestsAListItem() {
        let (controller, host) = makeEditor([Block(kind: .bullet, runs: [TextRun("one")])])
        host.editorSelection = NSRange(location: 1, length: 0)
        controller.selectionDidChange()
        controller.indent()
        #expect(controller.document.blocks[0].level == 1)
        controller.outdent()
        #expect(controller.document.blocks[0].level == 0)
    }

    @Test func typingSurvivesTheTextViewGoingAway() {
        var host: FakeHost? = FakeHost()
        let controller = EditorController(document: PageDocument(blocks: [Block()]))
        controller.attach(to: host!)
        host!.type("kept", with: controller)
        host = nil
        #expect(controller.document.blocks.map(\.plainText) == ["kept"])

        let rebuilt = FakeHost()
        controller.attach(to: rebuilt)
        #expect(rebuilt.editorStorage.string == "kept")
    }

    @Test func checkingAnItem() {
        let (controller, host) = makeEditor([Block(kind: .checklist, runs: [TextRun("task")])])
        controller.toggleCheck(atParagraphContaining: 0)
        #expect(controller.document.blocks[0].isChecked)
        #expect(host.editorStorage.string == "task")
    }

    @Test func changingBlockKindOnTheEmptyLastLine() {
        let (controller, host) = makeEditor([Block(runs: [TextRun("text")]), Block()])
        host.editorSelection = NSRange(location: 5, length: 0)
        controller.selectionDidChange()
        controller.setBlockKind(.bullet)
        #expect(controller.document.blocks.map(\.kind) == [.paragraph, .bullet])
        host.type("item", with: controller)
        #expect(controller.document.blocks.last == Block(kind: .bullet, runs: [TextRun("item")]))
    }

    @Test func insertingATableLeavesALineToKeepTyping() {
        let (controller, host) = makeEditor()
        controller.insertTable()
        #expect(controller.document.blocks.map(\.kind) == [.table, .paragraph])
        host.type("after", with: controller)
        #expect(controller.document.blocks.last?.plainText == "after")
    }

    @Test func placingAQuoteUsesItsOwnLinesAndLeavesALineToKeepTyping() {
        let (controller, host) = makeEditor([Block(runs: [TextRun("before")])])
        host.editorSelection = NSRange(location: 6, length: 0)
        controller.selectionDidChange()

        controller.insertBlocks([
            Block(kind: .quote, runs: [TextRun("Words")]),
            Block(kind: .quote, runs: [TextRun("— Someone")]),
        ])

        #expect(controller.document.blocks.map(\.kind) == [.paragraph, .quote, .quote, .paragraph])
        #expect(controller.document.blocks.map(\.plainText) == ["before", "Words", "— Someone", ""])
        host.type("after", with: controller)
        #expect(controller.document.blocks.last == Block(runs: [TextRun("after")]))
    }

    @Test func placingAQuoteOnAnEmptyLineReplacesThatLine() {
        let (controller, host) = makeEditor()
        controller.insertBlocks([Block(kind: .quote, runs: [TextRun("Words")])])
        #expect(controller.document.blocks.map(\.kind) == [.quote, .paragraph])
        // The controller only holds a weak reference, so the host must outlive the checks above.
        withExtendedLifetime(host) {}
    }

    @Test func placingAQuoteInTheMiddleKeepsTheLinesAround() {
        let (controller, host) = makeEditor([Block(runs: [TextRun("one")]), Block(runs: [TextRun("two")])])
        host.editorSelection = NSRange(location: 3, length: 0)
        controller.selectionDidChange()
        controller.insertBlocks([Block(kind: .quote, runs: [TextRun("Words")])])
        #expect(controller.document.blocks.map(\.plainText) == ["one", "Words", "two"])
    }

    @Test func placingAQuoteCanBeUndone() {
        let (controller, host) = makeEditor([Block(runs: [TextRun("before")])])
        host.editorSelection = NSRange(location: 6, length: 0)
        controller.selectionDidChange()
        controller.insertBlocks([Block(kind: .quote, runs: [TextRun("Words")])])
        host.undoLast()
        #expect(controller.document.blocks == [Block(runs: [TextRun("before")])])
    }

    @Test func findOpensOnTheTextView() {
        let (controller, host) = makeEditor()
        controller.showFind()
        #expect(host.findRequests == 1)
    }

    @Test func selectedTextComesBackPlain() {
        let (controller, host) = makeEditor([
            Block(runs: [TextRun("Hello "), styled("bold") { $0.bold = true }]),
            Block(kind: .bullet, runs: [TextRun("second")]),
        ])
        #expect(controller.selectedPlainText() == nil)
        host.editorSelection = NSRange(location: 6, length: 11)
        #expect(controller.selectedPlainText() == "bold\nsecond")
    }

    private func tablePage() -> (EditorController, FakeHost) {
        makeEditor([
            Block(runs: [TextRun("before")]),
            Block(kind: .table, table: TableData(rows: [["a"]])),
            Block(runs: [TextRun("after")]),
        ])
    }

    @Test func backspaceAfterATableKeepsEverything() {
        let (controller, host) = tablePage()
        // "before\n" is 7 characters, the table is 1 and its line break is 1.
        host.editorSelection = NSRange(location: 9, length: 0)
        controller.selectionDidChange()
        host.backspace(with: controller)
        #expect(controller.document.blocks.map(\.kind) == [.paragraph, .table, .paragraph])
        #expect(controller.document.blocks.last?.plainText == "after")
        #expect(host.editorSelection.location == 9)
    }

    @Test func backspaceBeforeATableKeepsEverything() {
        let (controller, host) = tablePage()
        host.editorSelection = NSRange(location: 7, length: 0)
        controller.selectionDidChange()
        host.backspace(with: controller)
        #expect(controller.document.blocks.map(\.kind) == [.paragraph, .table, .paragraph])
        #expect(controller.document.blocks.first?.plainText == "before")
    }

    @Test func backspaceAfterADividerKeepsTheText() {
        let (controller, host) = makeEditor([Block(kind: .divider), Block(runs: [TextRun("after")])])
        host.editorSelection = NSRange(location: 2, length: 0)
        controller.selectionDidChange()
        host.backspace(with: controller)
        #expect(controller.document.blocks.map(\.kind) == [.divider, .paragraph])
        #expect(controller.document.blocks.last?.plainText == "after")
    }

    @Test func savingNeverDropsTextSharingALineWithATable() {
        let text = NSMutableAttributedString(string: "left", attributes: EditorStyle.attributes(style: TextStyle(), block: BlockInfo()))
        text.append(DocumentConverter.attributedString(from: PageDocument(blocks: [Block(kind: .table, table: .empty())])))
        text.append(NSAttributedString(string: "right", attributes: EditorStyle.attributes(style: TextStyle(), block: BlockInfo())))
        let blocks = DocumentConverter.document(from: text).blocks
        #expect(blocks.map(\.kind) == [.paragraph, .table, .paragraph])
        #expect(blocks.filter { $0.kind != .table }.map(\.plainText) == ["left", "right"])
    }

    @Test func typingOnATableStartsANewLineAfterIt() {
        let (controller, host) = tablePage()
        host.editorSelection = NSRange(location: 8, length: 0)
        controller.selectionDidChange()
        host.type("x", with: controller)
        #expect(controller.document.blocks.map(\.kind) == [.paragraph, .table, .paragraph, .paragraph])
        #expect(controller.document.blocks.filter { $0.kind != .table }.map(\.plainText) == ["before", "x", "after"])
    }

    @Test func returnAfterAHeadingWithTextBelow() {
        let (controller, host) = makeEditor([
            Block(kind: .heading1, runs: [TextRun("Title")]),
            Block(runs: [TextRun("next")]),
        ])
        host.editorSelection = NSRange(location: 5, length: 0)
        controller.selectionDidChange()
        host.type("\n", with: controller)
        #expect(controller.document.blocks.map(\.kind) == [.heading1, .paragraph, .paragraph])
        #expect(controller.document.blocks.map(\.plainText) == ["Title", "", "next"])
        #expect(host.editorSelection.location == 6)
    }

    @Test func pastingATableIntoATextLineSplitsIt() {
        let (controller, host) = makeEditor([Block(runs: [TextRun("abcd")])])
        host.editorSelection = NSRange(location: 2, length: 0)
        controller.selectionDidChange()
        controller.paste(ClipboardContents(html: Data("<table><tr><td>x</td></tr></table>".utf8)))
        #expect(controller.document.blocks.map(\.kind) == [.paragraph, .table, .paragraph])
        #expect(controller.document.blocks.filter { $0.kind != .table }.map(\.plainText) == ["ab", "cd"])
    }

    @Test func editingATableCellAsksToSave() {
        let (controller, host) = makeEditor()
        controller.insertTable()
        var saves = 0
        controller.onChange = { saves += 1 }
        let attachment = host.editorStorage.attribute(.attachment, at: 0, effectiveRange: nil) as? TableAttachment
        attachment?.model.setCell(row: 0, column: 0, to: "Job")
        #expect(saves == 1)
        #expect(controller.document.blocks[0].table?.rows[0][0] == "Job")
    }
}

@Suite("Pasting")
@MainActor
struct PasteTests {
    @Test func htmlKeepsStylesListsAndLinks() {
        let document = PasteImporter.document(fromHTML: """
        <p>plain <b>bold</b> <i>italic</i> <s>struck</s> <a href="https://example.com">link</a></p>
        <ul><li>one</li><li>two</li></ul>
        <ol><li>first</li></ol>
        """)
        let blocks = document.blocks.filter { !$0.plainText.isEmpty }
        let runs = blocks[0].runs
        #expect(runs.contains { $0.text == "bold" && $0.style.bold })
        #expect(runs.contains { $0.text == "italic" && $0.style.slant == .italic })
        #expect(runs.contains { $0.text == "struck" && $0.style.strikethrough })
        #expect(runs.contains { $0.text == "link" && $0.style.link?.hasPrefix("https://example.com") == true })
        #expect(blocks[1].kind == .bullet && blocks[1].plainText == "one")
        #expect(blocks[2].kind == .bullet && blocks[2].plainText == "two")
        #expect(blocks[3].kind == .numbered && blocks[3].plainText == "first")
    }

    @Test func htmlTablesBecomeTables() {
        let document = PasteImporter.document(fromHTML: """
        <p>before</p>
        <table><tr><th>Job</th><th>Status</th></tr><tr><td>A &amp; B</td><td>Applied</td></tr></table>
        <p>after</p>
        """)
        let table = document.blocks.first { $0.kind == .table }?.table
        #expect(table?.rows == [["Job", "Status"], ["A & B", "Applied"]])
        #expect(document.blocks.first?.plainText == "before")
        #expect(document.blocks.last?.plainText == "after")
    }

    @Test func dangerousContentIsDropped() {
        let document = PasteImporter.document(fromHTML: """
        <p>safe <a href="javascript:alert(1)">bad</a></p>
        <script>alert(1)</script>
        <img src="https://example.com/track.png">
        """)
        let text = document.plainText
        #expect(text.contains("safe"))
        #expect(!text.contains("alert"))
        #expect(document.blocks.flatMap(\.runs).allSatisfy { $0.style.link == nil })
    }

    @Test func remoteLoadsAreRemovedButTextIsLeftAlone() {
        let document = PasteImporter.document(fromHTML: """
        <p style="background:url(https://example.com/a.png)" background="https://example.com/b.png">call url(foo) here</p>
        """)
        #expect(document.plainText == "call url(foo) here")
    }

    // Many apps write an empty line as a paragraph holding one non-breaking space.
    @Test func linesWithOnlySpacesBecomeBlankText() {
        let document = PasteImporter.document(fromHTML: """
        <p>first</p>
        <p>&nbsp;</p>
        <p>second</p>
        <p>   &nbsp; </p>
        <p><b>&nbsp;</b></p>
        <p>third</p>
        <p>&nbsp;</p>
        """)
        #expect(document.blocks.allSatisfy { $0.kind == .paragraph })
        #expect(document.blocks.allSatisfy { $0.plainText == $0.plainText.trimmingCharacters(in: .whitespacesAndNewlines) })
        #expect(document.blocks.filter { !$0.plainText.isEmpty }.map(\.plainText) == ["first", "second", "third"])
        #expect(document.blocks.last?.plainText == "third")
    }

    @Test func realCodeIsStillRecognized() {
        let document = PasteImporter.document(fromHTML: "<p>words</p><p><code>let a = 1</code></p>")
        let code = document.blocks.first { $0.plainText == "let a = 1" }
        #expect(code?.kind == .code)
        #expect(document.blocks.first?.kind == .paragraph)
    }

    @Test func plainTextBecomesParagraphs() {
        let document = PasteImporter.document(fromPlainText: "one\n\ntwo")
        #expect(document.blocks.map(\.plainText) == ["one", "", "two"])
    }

    @Test func ownFormatComesBackExactly() throws {
        let original = PageDocument(blocks: [Block(runs: [styled("back") { $0.slant = .backwards }])])
        let clipboard = ClipboardContents(journal: try original.encoded(), html: Data("<p>other</p>".utf8))
        #expect(PasteImporter.document(from: clipboard) == original)
    }

    @Test func pastingOneLineTakesOnTheBlockItLandsIn() {
        let (controller, host) = makeEditor([Block(kind: .bullet, runs: [TextRun("ab")])])
        host.editorSelection = NSRange(location: 1, length: 0)
        controller.selectionDidChange()
        controller.paste(ClipboardContents(text: "XY"))
        #expect(controller.document.blocks == [Block(kind: .bullet, runs: [TextRun("aXYb")])])
    }
}

@Suite("Typing a marker to start a list")
@MainActor
struct ListShortcutTests {
    @Test(arguments: [("*", BlockKind.bullet), ("-", .dash), ("-0", .checklist), ("1.", .numbered)])
    func aMarkerAndASpaceStartAList(marker: String, kind: BlockKind) {
        let (controller, host) = makeEditor()
        host.type(marker, with: controller)
        host.type(" ", with: controller)
        #expect(controller.state.blockKind == kind)
        host.type("item", with: controller)
        #expect(controller.document.blocks == [Block(kind: kind, runs: [TextRun("item")])])
    }

    @Test func worksOnALineInTheMiddleOfThePage() {
        let (controller, host) = makeEditor([Block(runs: [TextRun("above")]), Block(), Block(runs: [TextRun("below")])])
        host.editorSelection = NSRange(location: 6, length: 0)
        controller.selectionDidChange()
        host.type("-", with: controller)
        host.type(" ", with: controller)
        host.type("item", with: controller)
        #expect(controller.document.blocks.map(\.kind) == [.paragraph, .dash, .paragraph])
        #expect(controller.document.plainText == "above\nitem\nbelow")
    }

    @Test func aDashAndZeroWithoutASpaceStaysText() {
        let (controller, host) = makeEditor()
        host.type("-", with: controller)
        host.type("0", with: controller)
        #expect(controller.document.blocks == [Block(runs: [TextRun("-0")])])
        #expect(controller.state.blockKind == .paragraph)
    }

    @Test func aDashAndALongerNumberStaysText() {
        let (controller, host) = makeEditor()
        for character in ["-", "0", "5", " "] { host.type(character, with: controller) }
        #expect(controller.document.blocks == [Block(runs: [TextRun("-05 ")])])
    }

    @Test func returnInADashListStartsAnotherDash() {
        let (controller, host) = makeEditor()
        host.type("-", with: controller)
        host.type(" ", with: controller)
        host.type("one", with: controller)
        host.type("\n", with: controller)
        host.type("two", with: controller)
        #expect(controller.document.blocks == [
            Block(kind: .dash, runs: [TextRun("one")]),
            Block(kind: .dash, runs: [TextRun("two")]),
        ])
    }

    @Test func theListButtonsSwitchBetweenDashesAndBullets() {
        let (controller, host) = makeEditor([Block(kind: .dash, runs: [TextRun("item")], textKind: .code)])
        withExtendedLifetime(host) {
            controller.selectionDidChange()
            controller.setBlockKind(.bullet)
            #expect(controller.document.blocks == [Block(kind: .bullet, runs: [TextRun("item")], textKind: .code)])
            controller.setBlockKind(.dash)
            #expect(controller.document.blocks == [Block(kind: .dash, runs: [TextRun("item")], textKind: .code)])
            controller.setBlockKind(.dash)
            #expect(controller.document.blocks == [Block(kind: .code, runs: [TextRun("item")])])
        }
    }

    @Test func aDashStaysADashAtEveryLevelAndABulletNeverBecomesOne() {
        for level in 0..<6 {
            #expect(EditorStyle.marker(for: BlockInfo(kind: .dash, level: level)) == "–")
            #expect(EditorStyle.marker(for: BlockInfo(kind: .bullet, level: level)) != "–")
        }
    }

    @Test func pastedDashListsStayDashLists() {
        let document = PasteImporter.document(fromHTML: #"<ul style="list-style-type: '- '"><li>one</li></ul><ul><li>two</li></ul>"#)
        let blocks = document.blocks.filter { !$0.plainText.isEmpty }
        #expect(blocks.map(\.kind) == [.dash, .bullet])
        #expect(blocks.map(\.plainText) == ["one", "two"])
    }

    @Test func turnsExistingTextIntoAListItem() {
        let (controller, host) = makeEditor([Block(runs: [TextRun("words")])])
        host.editorSelection = NSRange(location: 0, length: 0)
        controller.selectionDidChange()
        host.type("*", with: controller)
        host.type(" ", with: controller)
        #expect(controller.document.blocks == [Block(kind: .bullet, runs: [TextRun("words")])])
        #expect(host.editorSelection.location == 0)
    }

    @Test(arguments: ["a *", "2.", "1", "**"])
    func otherTextStaysText(typed: String) {
        let (controller, host) = makeEditor()
        host.type(typed, with: controller)
        host.type(" ", with: controller)
        #expect(controller.document.blocks == [Block(runs: [TextRun(typed + " ")])])
    }

    @Test func aMarkerInCodeStaysCode() {
        let (controller, host) = makeEditor([Block(kind: .code)])
        host.type("-", with: controller)
        host.type(" ", with: controller)
        #expect(controller.document.blocks[0].kind == .code)
        #expect(controller.document.blocks[0].plainText == "- ")
    }

    @Test func undoBringsTheMarkerBack() {
        let (controller, host) = makeEditor()
        host.type("1.", with: controller)
        host.type(" ", with: controller)
        host.undoLast()
        #expect(controller.document.blocks == [Block(runs: [TextRun("1.")])])
    }

    @Test func numberingCountsUp() {
        let (controller, host) = makeEditor()
        host.type("1.", with: controller)
        host.type(" ", with: controller)
        host.type("one", with: controller)
        host.type("\n", with: controller)
        host.type("two", with: controller)
        #expect(controller.document.blocks.map(\.kind) == [.numbered, .numbered])
        #expect(EditorEngine.block(host.editorStorage, paragraph: EditorEngine.paragraphRange(host.editorStorage, at: 5)).number == 2)
    }
}

@Suite("Code inside list items")
@MainActor
struct CodeInListTests {
    private func codeItem(_ text: String = "code", kind: BlockKind = .numbered) -> Block {
        Block(kind: kind, runs: [TextRun(text)], textKind: .code)
    }

    @Test(arguments: [BlockKind.bullet, .dash, .numbered, .checklist])
    func choosingCodeKeepsTheList(kind: BlockKind) {
        let (controller, host) = makeEditor([Block(kind: kind, runs: [TextRun("code")])])
        controller.selectionDidChange()
        #expect(controller.state.textKind == .paragraph)
        controller.setBlockKind(.code)
        #expect(controller.document.blocks == [codeItem(kind: kind)])
        #expect(controller.state.blockKind == kind)
        #expect(controller.state.textKind == .code)
        #expect(host.editorStorage.string == "code")
    }

    @Test func choosingAListKeepsTheCode() {
        let (controller, host) = makeEditor([Block(kind: .code, runs: [TextRun("code")])])
        // The controller only holds the text view weakly, so this keeps it around.
        withExtendedLifetime(host) {
            controller.selectionDidChange()
            controller.setBlockKind(.numbered)
            #expect(controller.document.blocks == [codeItem()])
        }
    }

    @Test func turningTheListOffLeavesACodeBlock() {
        let (controller, host) = makeEditor([codeItem()])
        // The controller only holds the text view weakly, so this keeps it around.
        withExtendedLifetime(host) {
            controller.selectionDidChange()
            controller.setBlockKind(.numbered)
            #expect(controller.document.blocks == [Block(kind: .code, runs: [TextRun("code")])])
        }
    }

    @Test func choosingTextLeavesAPlainListItem() {
        let (controller, host) = makeEditor([codeItem()])
        // The controller only holds the text view weakly, so this keeps it around.
        withExtendedLifetime(host) {
            controller.selectionDidChange()
            controller.setBlockKind(.paragraph)
            #expect(controller.document.blocks == [Block(kind: .numbered, runs: [TextRun("code")])])
        }
    }

    @Test func codeUsesTheCodeFontAndSitsInsideTheList() throws {
        let (_, host) = makeEditor([codeItem()])
        let font = try #require(host.editorStorage.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        #expect(font.fontName.contains("Menlo"))
        let block = BlockInfo(kind: .numbered, textKind: .code)
        #expect(EditorStyle.headIndent(for: block) == EditorStyle.listIndent(for: block) + 10)
    }

    @Test func returnAddsALineOfCodeBesideTheSameNumber() {
        let (controller, host) = makeEditor([codeItem("one")])
        host.editorSelection = NSRange(location: 3, length: 0)
        controller.selectionDidChange()
        host.type("\n", with: controller)
        host.type("two", with: controller)
        #expect(controller.document.blocks == [codeItem("one\u{2028}two")])
    }

    @Test func returnOnAnEmptyLineEndsTheCodeAndStartsTheNextItem() {
        let (controller, host) = makeEditor([codeItem("one")])
        host.editorSelection = NSRange(location: 3, length: 0)
        controller.selectionDidChange()
        host.type("\n", with: controller)
        host.type("\n", with: controller)
        host.type("next", with: controller)
        #expect(controller.document.blocks == [codeItem("one"), Block(kind: .numbered, runs: [TextRun("next")])])
        #expect(EditorEngine.block(host.editorStorage, paragraph: EditorEngine.paragraphRange(host.editorStorage, at: 5)).number == 2)
    }

    @Test func aCodeLineEndingThePageDoesNotAddABlock() {
        let (controller, host) = makeEditor([codeItem("one")])
        host.editorSelection = NSRange(location: 3, length: 0)
        controller.selectionDidChange()
        host.type("\n", with: controller)
        #expect(controller.document.blocks == [codeItem("one\u{2028}")])
    }

    @Test func numbersCountAcrossCodeItems() {
        let (_, host) = makeEditor([codeItem("a"), Block(kind: .numbered, runs: [TextRun("b")]), codeItem("c")])
        #expect(EditorEngine.block(host.editorStorage, paragraph: EditorEngine.paragraphRange(host.editorStorage, at: 4)).number == 3)
    }

    @Test func backspaceRemovesTheCodeBeforeTheList() {
        let (controller, host) = makeEditor([codeItem()])
        host.editorSelection = NSRange(location: 1, length: 0)
        host.backspace(with: controller)
        #expect(controller.document.blocks == [codeItem("ode")])
        host.editorSelection = NSRange(location: 0, length: 0)
        controller.selectionDidChange()
        let storage = host.editorStorage
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: NSAttributedString(string: "\n", attributes: storage.attributes(at: 0, effectiveRange: nil)))
        host.editorSelection = NSRange(location: 1, length: 0)
        controller.selectionDidChange()
        host.backspace(with: controller)
        #expect(controller.document.blocks.last?.kind == .numbered)
        #expect(controller.document.blocks.last?.textKind == .paragraph)
    }

    @Test func aTabIsPartOfTheCode() {
        let (controller, host) = makeEditor([codeItem("a")])
        host.editorSelection = NSRange(location: 1, length: 0)
        controller.selectionDidChange()
        host.type("\t", with: controller)
        #expect(controller.document.blocks == [codeItem("a\t")])
    }

    @Test func aPageWithCodeItemsSurvivesARoundTrip() {
        let document = PageDocument(blocks: [
            codeItem("a\u{2028}b", kind: .bullet),
            Block(kind: .numbered, runs: [TextRun("title")], level: 1, textKind: .heading2),
            Block(kind: .checklist, runs: [TextRun("said")], isChecked: true, textKind: .quote),
        ])
        let text = DocumentConverter.attributedString(from: document)
        #expect(DocumentConverter.document(from: text) == document)
    }
}

@Suite("Autocorrect")
@MainActor
struct AutocorrectTests {
    // What the iPhone does: it reports the change, clears the typing attributes, then brings its
    // own text with none of the app's settings on it.
    private func autocorrect(_ range: NSRange, to word: String, in host: FakeHost, with controller: EditorController) {
        #expect(controller.shouldChangeText(in: range, replacement: word))
        host.editorTypingAttributes = [:]
        host.editorStorage.replaceCharacters(in: range, with: NSAttributedString(string: word))
        controller.textDidChange()
    }

    @Test func fixingTheFirstWordKeepsTheItemInItsList() {
        let (controller, host) = makeEditor([Block(kind: .numbered, runs: [TextRun("teh")])])
        host.editorSelection = NSRange(location: 3, length: 0)
        controller.selectionDidChange()
        autocorrect(NSRange(location: 0, length: 3), to: "the", in: host, with: controller)
        #expect(controller.document.blocks == [Block(kind: .numbered, runs: [TextRun("the")])])
        #expect(controller.state.blockKind == .numbered)
    }

    @Test func fixingAWordInCodeInAListKeepsBoth() {
        let (controller, host) = makeEditor([Block(kind: .bullet, runs: [TextRun("teh")], textKind: .code)])
        host.editorSelection = NSRange(location: 3, length: 0)
        controller.selectionDidChange()
        autocorrect(NSRange(location: 0, length: 3), to: "the", in: host, with: controller)
        #expect(controller.document.blocks == [Block(kind: .bullet, runs: [TextRun("the")], textKind: .code)])
    }

    @Test func aFixedWordKeepsItsBoldAndTypingContinuesInTheList() {
        let (controller, host) = makeEditor([Block(kind: .bullet, runs: [styled("teh") { $0.bold = true }])])
        host.editorSelection = NSRange(location: 3, length: 0)
        controller.selectionDidChange()
        autocorrect(NSRange(location: 0, length: 3), to: "the", in: host, with: controller)
        host.type(" end", with: controller)
        #expect(controller.document.blocks == [Block(kind: .bullet, runs: [styled("the end") { $0.bold = true }])])
    }

    // Moving away from a word can accept a correction with no report at all.
    @Test func aFixWithNoReportStillKeepsTheList() {
        let (controller, host) = makeEditor([Block(kind: .numbered, runs: [TextRun("teh")])])
        host.editorSelection = NSRange(location: 3, length: 0)
        controller.selectionDidChange()
        host.editorStorage.replaceCharacters(in: NSRange(location: 0, length: 3), with: NSAttributedString(string: "the"))
        #expect(controller.document.blocks == [Block(kind: .numbered, runs: [TextRun("the")])])
    }
}
