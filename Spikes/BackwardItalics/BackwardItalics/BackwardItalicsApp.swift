// Throwaway test: can Apple's real text editors show backwards italics?
//
// Shows sample text in NSTextView (Mac) and UITextView (iPhone), the same editors the
// journal will build on. It compares two techniques and has a button that applies
// backwards italics to selected text, to prove it works on live editing.

import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#endif

// How far the text leans. Negative means left, which is "backwards".
let backwardsSlant: CGFloat = -0.25

extension PlatformColor {
    static var bodyText: PlatformColor {
        #if canImport(UIKit)
        return .label
        #else
        return .labelColor
        #endif
    }
}

func font(_ name: String?, size: CGFloat = 20, bold: Bool = false) -> PlatformFont {
    if let name, let named = PlatformFont(name: name, size: size) {
        return named
    }
    return bold ? PlatformFont.boldSystemFont(ofSize: size) : PlatformFont.systemFont(ofSize: size)
}

func italicFont(size: CGFloat = 20) -> PlatformFont {
    #if canImport(UIKit)
    return UIFont.italicSystemFont(ofSize: size)
    #else
    let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(.italic)
    return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    #endif
}

// Technique 2: copy any font, with its letters skewed by a transform.
func backwards(_ font: PlatformFont) -> PlatformFont {
    var matrix = CGAffineTransform(a: 1, b: 0, c: backwardsSlant, d: 1, tx: 0, ty: 0)
    return CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize, &matrix, nil) as PlatformFont
}

// What the editor button does. Selected text can mix fonts, so each run keeps its own.
func makeBackwards(in storage: NSTextStorage, range: NSRange) {
    storage.enumerateAttribute(.font, in: range) { value, runRange, _ in
        guard let current = value as? PlatformFont else { return }
        storage.addAttribute(.font, value: backwards(current), range: runRange)
    }
}

func sampleText() -> NSAttributedString {
    let text = NSMutableAttributedString()

    func add(_ string: String, _ font: PlatformFont, slant: CGFloat? = nil) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: PlatformColor.bodyText]
        if let slant {
            attributes[.obliqueness] = slant
        }
        text.append(NSAttributedString(string: string + "\n", attributes: attributes))
    }

    add("Regular: The quick brown fox", font(nil))
    add("Italic: The quick brown fox", italicFont())
    add("Technique 1, obliqueness: The quick brown fox", font(nil), slant: backwardsSlant)
    add("Backwards: The quick brown fox", backwards(font(nil)))
    add("Backwards bold: The quick brown fox", backwards(font(nil, bold: true)))
    add("Backwards Georgia: The quick brown fox", backwards(font("Georgia")))
    add("Backwards Menlo: The quick brown fox", backwards(font("Menlo")))
    add("", font(nil))
    add("Wrapping: This long sentence leans backwards the whole way across the page, so we can see whether it wraps onto new lines, selects, and edits just like any normal text would in a journal entry.", backwards(font(nil)))
    add("", font(nil))
    add("Select this line, then press the button above.", font(nil))
    return text
}

// Lets the SwiftUI button reach the editor underneath it.
final class EditorLink: ObservableObject {
    var applyBackwards: () -> Void = {}
}

#if canImport(UIKit)
struct Editor: UIViewRepresentable {
    let link: EditorLink

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.attributedText = sampleText()
        view.backgroundColor = .clear
        link.applyBackwards = { [weak view] in
            guard let view, view.selectedRange.length > 0 else { return }
            makeBackwards(in: view.textStorage, range: view.selectedRange)
        }
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {}
}
#else
struct Editor: NSViewRepresentable {
    let link: EditorLink

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let view = scrollView.documentView as! NSTextView
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.textStorage?.setAttributedString(sampleText())
        link.applyBackwards = { [weak view] in
            guard let view, let storage = view.textStorage, view.selectedRange().length > 0 else { return }
            makeBackwards(in: storage, range: view.selectedRange())
        }
        saveSnapshotIfRequested(of: view, link: link)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    // Lets a script check the real rendering: BackwardItalics --snapshot /path/to/file.png
    // It also presses the button and types, to check live editing.
    private func saveSnapshotIfRequested(of view: NSTextView, link: EditorLink) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return }
        let path = arguments[index + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let content = view.string as NSString
            let lastLine = content.range(of: "Select this line, then press the button above.")
            view.setSelectedRange(lastLine)
            link.applyBackwards()
            view.setSelectedRange(NSRange(location: NSMaxRange(lastLine), length: 0))
            view.insertText(" Typed afterwards.", replacementRange: view.selectedRange())
            let bounds = view.bounds
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) {
                view.cacheDisplay(in: bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            print("TextKit 2 in use: \(view.textLayoutManager != nil)")
            NSApp.terminate(nil)
        }
    }
}
#endif

@main
struct BackwardItalicsApp: App {
    @StateObject private var link = EditorLink()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 0) {
                Button("Make selection backwards") { link.applyBackwards() }
                    .padding(12)
                Editor(link: link)
            }
            .frame(minWidth: 320, minHeight: 480)
        }
    }
}
