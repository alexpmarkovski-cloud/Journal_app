// Drives the real Mac text view, the same way the keyboard does.

#if os(macOS)
import AppKit
import JournalCore
import Testing
import SwiftUI
@testable import JournalEditor

@MainActor
private final class MacEditor {
    let controller: EditorController
    let coordinator: EditorCoordinator
    let view: RichNSTextView
    let window: NSWindow

    init(_ blocks: [Block]) {
        controller = EditorController(document: PageDocument(blocks: blocks))
        coordinator = EditorCoordinator(controller: controller)
        view = RichNSTextView.make(controller: controller, coordinator: coordinator)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
    }

    var kinds: [BlockKind] { controller.document.blocks.map(\.kind) }
    var texts: [String] { controller.document.blocks.map(\.plainText) }

    func caret(at location: Int) {
        view.setSelectedRange(NSRange(location: location, length: 0))
    }

    func type(_ text: String) {
        view.insertText(text, replacementRange: view.selectedRange())
    }
}

@Suite("Mac text view")
@MainActor
struct MacTextViewTests {
    @Test(arguments: [("*", BlockKind.bullet), ("-", .dash), ("-0", .checklist), ("1.", .numbered)])
    func typingAMarkerAndASpaceStartsAList(marker: String, kind: BlockKind) {
        let editor = MacEditor([Block()])
        editor.type(marker)
        editor.type(" ")
        editor.type("item")
        #expect(editor.controller.document.blocks == [Block(kind: kind, runs: [TextRun("item")])])
    }

    @Test func returnInACodeItemStaysBesideTheSameNumber() {
        let editor = MacEditor([Block(kind: .numbered, runs: [TextRun("one")], textKind: .code)])
        editor.caret(at: 3)
        editor.view.insertNewline(nil)
        editor.type("two")
        #expect(editor.controller.document.blocks == [Block(kind: .numbered, runs: [TextRun("one\u{2028}two")], textKind: .code)])
        editor.view.insertNewline(nil)
        editor.view.insertNewline(nil)
        editor.type("next")
        #expect(editor.controller.document.blocks.last == Block(kind: .numbered, runs: [TextRun("next")]))
        #expect(editor.controller.document.blocks.count == 2)
    }

    @Test func usesTextKit2() {
        #expect(MacEditor([Block()]).view.textLayoutManager != nil)
    }

    @Test func findBarOpensAboveThePage() {
        let editor = MacEditor([Block(runs: [TextRun("one two one")])])
        let scrollView = NSScrollView(frame: editor.view.frame)
        scrollView.documentView = editor.view
        editor.window.contentView = scrollView
        #expect(!scrollView.isFindBarVisible)

        editor.controller.showFind()

        #expect(scrollView.isFindBarVisible)
    }

    @Test func returnContinuesAndEndsAList() {
        let editor = MacEditor([Block(kind: .bullet, runs: [TextRun("one")])])
        editor.caret(at: 3)
        editor.view.insertNewline(nil)
        editor.type("two")
        #expect(editor.texts == ["one", "two"])
        #expect(editor.kinds == [.bullet, .bullet])

        editor.view.insertNewline(nil)
        editor.view.insertNewline(nil)
        editor.type("plain")
        #expect(editor.kinds == [.bullet, .bullet, .paragraph])
        #expect(editor.texts == ["one", "two", "plain"])
    }

    @Test func tabAndShiftTabChangeNesting() {
        let editor = MacEditor([Block(kind: .bullet, runs: [TextRun("one")])])
        editor.caret(at: 1)
        editor.view.insertTab(nil)
        #expect(editor.controller.document.blocks[0].level == 1)
        #expect(editor.texts == ["one"])
        editor.view.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(editor.controller.document.blocks[0].level == 0)
    }

    @Test func backspaceAtTheStartOfAnItemMakesItText() {
        let editor = MacEditor([
            Block(runs: [TextRun("top")]),
            Block(kind: .bullet, runs: [TextRun("one")]),
        ])
        editor.caret(at: 4)
        editor.view.deleteBackward(nil)
        #expect(editor.kinds == [.paragraph, .paragraph])
        #expect(editor.texts == ["top", "one"])
    }

    @Test func commandsAndTypingUndoInOrder() throws {
        let editor = MacEditor([Block(runs: [TextRun("hello")])])
        let undo = try #require(editor.view.undoManager)
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        editor.view.setSelectedRange(NSRange(location: 0, length: 5))
        editor.controller.selectionDidChange()
        editor.controller.toggleSlant(.backwards)
        undo.endUndoGrouping()
        #expect(editor.controller.document.blocks[0].runs[0].style.slant == .backwards)

        undo.undo()
        #expect(editor.controller.document.blocks[0].runs[0].style.slant == .none)
        undo.redo()
        #expect(editor.controller.document.blocks[0].runs[0].style.slant == .backwards)
    }

    @Test func aTableGetsAGridOverItsSpace() throws {
        let editor = MacEditor([
            Block(runs: [TextRun("before")]),
            Block(kind: .table, table: TableData(rows: [["a", "b"], ["c", "d"]])),
            Block(runs: [TextRun("after")]),
        ])
        editor.view.layout()
        let grid = try #require(editor.view.subviews.first { $0 is NSHostingView<TableBlockView> })
        #expect(grid.frame.height == CGFloat(2) * TableAttachment.rowHeight + 2 + TableAttachment.controlsHeight)
        #expect(grid.frame.minY > 8)

        // Deleting the table removes its grid.
        editor.view.setSelectedRange(NSRange(location: 7, length: 1))
        editor.view.delete(nil)
        editor.view.layout()
        #expect(!editor.view.subviews.contains { $0 is NSHostingView<TableBlockView> })
    }
}
#endif
