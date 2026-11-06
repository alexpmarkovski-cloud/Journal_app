// The editors themselves: UITextView on iPhone and NSTextView on Mac. These stay thin. They
// report what happens to EditorController, and handle only what's truly platform specific.

import JournalCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

private let journalPasteboardType = "local.journalapp.blocks"

// What the app places on screen. The platform versions are at the bottom of this file.
public struct RichTextEditor: View {
    let controller: EditorController

    public init(controller: EditorController) {
        self.controller = controller
    }

    public var body: some View {
        PlatformEditor(controller: controller)
    }
}

// Tells the text system to use our paragraph drawing. The text view has a delegate of its own
// that it relies on, so everything else is passed through to that one.
final class LayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    private weak var original: NSTextLayoutManagerDelegate?

    func install(on layoutManager: NSTextLayoutManager?) {
        original = layoutManager?.delegate
        layoutManager?.delegate = self
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let kind = EditorEngine.blockAttribute(paragraph.attributedString, at: 0)?.kind,
           BlockLayoutFragment.decorates(kind) {
            return BlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        return original?.textLayoutManager?(textLayoutManager, textLayoutFragmentFor: location, in: textElement)
            ?? NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }
}

// Finds the paragraph under a point, for tapping checkboxes.
@MainActor
private func checkboxLocation(at point: CGPoint, layoutManager: NSTextLayoutManager?) -> Int? {
    guard let layoutManager,
          let fragment = layoutManager.textLayoutFragment(for: point) as? BlockLayoutFragment else { return nil }
    let frame = fragment.layoutFragmentFrame
    guard fragment.checkboxContains(CGPoint(x: point.x, y: point.y - frame.minY)),
          let start = fragment.rangeInElement.location as NSTextLocation?,
          let content = layoutManager.textContentManager else { return nil }
    return content.offset(from: content.documentRange.location, to: start)
}

#if canImport(UIKit)

final class RichUITextView: UITextView, EditorHost {
    weak var controller: EditorController?

    var editorStorage: NSTextStorage { textStorage }
    var editorSelection: NSRange {
        get { selectedRange }
        set { selectedRange = newValue }
    }
    var editorTypingAttributes: [NSAttributedString.Key: Any] {
        get { typingAttributes }
        set { typingAttributes = newValue }
    }
    var editorUndoManager: UndoManager? { undoManager }
    var isComposingText: Bool { markedTextRange != nil }
    func prepareForEditorUndo() {}
    func tablesChanged() { setNeedsLayout() }
    func showFind() { findInteraction?.presentFindNavigator(showingReplace: false) }

    // Starts as nil on purpose. Text views that use TextKit 2 are built by an older factory
    // method that skips Swift's default property values, so `= TableOverlays()` would crash.
    private var tables: TableOverlays?

    override func layoutSubviews() {
        super.layoutSubviews()
        let overlays = tables ?? TableOverlays()
        tables = overlays
        overlays.update(
            in: self,
            storage: textStorage,
            layoutManager: textLayoutManager,
            origin: CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        )
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        controller?.paste(ClipboardContents(
            journal: board.data(forPasteboardType: journalPasteboardType),
            html: board.data(forPasteboardType: "public.html"),
            rtf: board.data(forPasteboardType: "public.rtf"),
            text: board.string
        ))
    }

    override func copy(_ sender: Any?) {
        let data = controller?.selectedDocumentData()
        super.copy(sender)
        addJournalData(data)
    }

    override func cut(_ sender: Any?) {
        let data = controller?.selectedDocumentData()
        super.cut(sender)
        addJournalData(data)
    }

    private func addJournalData(_ data: Data?) {
        guard let data else { return }
        UIPasteboard.general.addItems([[journalPasteboardType: data]])
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        var point = gesture.location(in: self)
        point.x -= textContainerInset.left
        point.y -= textContainerInset.top
        if let location = checkboxLocation(at: point, layoutManager: textLayoutManager) {
            controller?.toggleCheck(atParagraphContaining: location)
        }
    }
}

final class EditorCoordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
    let controller: EditorController
    let layoutDelegate = LayoutDelegate()

    init(controller: EditorController) {
        self.controller = controller
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        controller.shouldChangeText(in: range, replacement: text)
    }

    func textViewDidChange(_ textView: UITextView) {
        controller.textDidChange()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        controller.selectionDidChange()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

private struct PlatformEditor: UIViewRepresentable {
    let controller: EditorController

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(controller: controller)
    }

    func makeUIView(context: Context) -> RichUITextView {
        let view = RichUITextView(usingTextLayoutManager: true)
        context.coordinator.layoutDelegate.install(on: view.textLayoutManager)
        view.controller = controller
        view.backgroundColor = .clear
        view.font = PlatformFont.systemFont(ofSize: EditorStyle.bodySize)
        view.textContainerInset = UIEdgeInsets(top: 8, left: 20, bottom: 40, right: 20)
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.isFindInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: view, action: #selector(RichUITextView.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        controller.attach(to: view)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: RichUITextView, context: Context) {}
}

#else

final class RichNSTextView: NSTextView, EditorHost {
    weak var controller: EditorController?

    static func make(controller: EditorController, coordinator: EditorCoordinator) -> RichNSTextView {
        let view = RichNSTextView(usingTextLayoutManager: true)
        coordinator.layoutDelegate.install(on: view.textLayoutManager)
        view.controller = controller
        view.isRichText = true
        view.importsGraphics = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 24, height: 8)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        controller.attach(to: view)
        view.delegate = coordinator
        return view
    }

    var editorStorage: NSTextStorage { textStorage ?? NSTextStorage() }
    var editorSelection: NSRange {
        get { selectedRange() }
        set { setSelectedRange(newValue) }
    }
    var editorTypingAttributes: [NSAttributedString.Key: Any] {
        get { typingAttributes }
        set { typingAttributes = newValue }
    }
    var editorUndoManager: UndoManager? { undoManager }
    var isComposingText: Bool { hasMarkedText() }
    func prepareForEditorUndo() { breakUndoCoalescing() }
    func tablesChanged() { needsLayout = true }
    func showFind() {
        // The text view reads which find command to run from the sender's tag.
        let command = NSMenuItem()
        command.tag = NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(command)
    }

    // Starts as nil on purpose. Text views that use TextKit 2 are built by an older factory
    // method that skips Swift's default property values, so `= TableOverlays()` would crash.
    private var tables: TableOverlays?

    override func layout() {
        super.layout()
        let overlays = tables ?? TableOverlays()
        tables = overlays
        overlays.update(in: self, storage: editorStorage, layoutManager: textLayoutManager, origin: textContainerOrigin)
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        controller?.paste(ClipboardContents(
            journal: board.data(forType: NSPasteboard.PasteboardType(journalPasteboardType)),
            html: board.data(forType: .html),
            rtf: board.data(forType: .rtf),
            text: board.string(forType: .string)
        ))
    }

    override func copy(_ sender: Any?) {
        let data = controller?.selectedDocumentData()
        super.copy(sender)
        addJournalData(data)
    }

    override func cut(_ sender: Any?) {
        let data = controller?.selectedDocumentData()
        super.cut(sender)
        addJournalData(data)
    }

    private func addJournalData(_ data: Data?) {
        guard let data else { return }
        let type = NSPasteboard.PasteboardType(journalPasteboardType)
        NSPasteboard.general.addTypes([type], owner: nil)
        NSPasteboard.general.setData(data, forType: type)
    }

    override func mouseDown(with event: NSEvent) {
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        if let location = checkboxLocation(at: point, layoutManager: textLayoutManager) {
            controller?.toggleCheck(atParagraphContaining: location)
            return
        }
        super.mouseDown(with: event)
    }

    // The standard menu's font and style items would change how text looks without updating
    // what gets saved, so they're removed in favor of the format bar.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        for item in menu.items where item.submenu?.items.contains(where: { $0.action == #selector(NSFontManager.addFontTrait(_:)) }) == true {
            menu.removeItem(item)
        }
        return menu
    }
}

final class EditorCoordinator: NSObject, NSTextViewDelegate {
    let controller: EditorController
    let layoutDelegate = LayoutDelegate()

    init(controller: EditorController) {
        self.controller = controller
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        return controller.shouldChangeText(in: affectedCharRange, replacement: replacementString)
    }

    func textDidChange(_ notification: Notification) {
        controller.textDidChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        controller.selectionDidChange()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertBacktab(_:)), controller.state.isListItem {
            controller.outdent()
            return true
        }
        return false
    }
}

private struct PlatformEditor: NSViewRepresentable {
    let controller: EditorController

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(controller: controller)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = RichNSTextView.make(controller: controller, coordinator: context.coordinator)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = view
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

#endif
