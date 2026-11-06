// The row of formatting buttons. It sits above the keyboard on iPhone and above the page on Mac.

import JournalCore
import SwiftUI

public struct FormatBar: View {
    let controller: EditorController
    // The app's theme can paint the bar. Without it, the bar uses the system's own material.
    let background: Color?
    // Quotes live outside the editor, so the app decides what these do. Without them, the
    // matching menu items are hidden.
    let onInsertQuote: (() -> Void)?
    let onSaveSelectionAsQuote: ((String) -> Void)?

    @Environment(\.openURL) private var openURL
    @State private var isAskingForLink = false
    @State private var linkText = ""
    @State private var linkFailed = false

    private static let sizes: [Double] = [10, 12, 14, 15, 17, 20, 24, 28, 36, 48, 72]

    public init(
        controller: EditorController,
        background: Color? = nil,
        onInsertQuote: (() -> Void)? = nil,
        onSaveSelectionAsQuote: ((String) -> Void)? = nil
    ) {
        self.controller = controller
        self.background = background
        self.onInsertQuote = onInsertQuote
        self.onSaveSelectionAsQuote = onSaveSelectionAsQuote
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                textStyleButtons
                divider
                listMenu
                divider
                blockMenu
                fontMenu
                sizeMenu
                divider
                linkButton
                insertMenu
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(background.map(AnyShapeStyle.init) ?? AnyShapeStyle(.bar))
        .alert("Link", isPresented: $isAskingForLink) {
            TextField("example.com", text: $linkText)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            Button("Save") { linkFailed = !controller.setLink(linkText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Web and email links only.")
        }
        .alert("Couldn't add that link", isPresented: $linkFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Put the caret on a word or select some text, and use a web or email address.")
        }
    }

    private var state: FormatState { controller.state }

    private var divider: some View {
        Divider().frame(height: 22).padding(.horizontal, 4)
    }

    // MARK: Text style

    private var textStyleButtons: some View {
        Group {
            toggle("Bold", isOn: state.bold, shortcut: "b", action: controller.toggleBold) {
                Text("B").fontWeight(.bold)
            }
            toggle("Italic", isOn: state.slant == .italic, shortcut: "i", action: { controller.toggleSlant(.italic) }) {
                Text("I").italic()
            }
            toggle("Backwards italic", isOn: state.slant == .backwards, shortcut: "j", action: { controller.toggleSlant(.backwards) }) {
                // SwiftUI has no backwards italic, so the button's letter is leaned by hand.
                Text("I").transformEffect(CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: -3, ty: 0))
            }
            toggle("Strikethrough", isOn: state.strikethrough, shortcut: nil, action: controller.toggleStrikethrough) {
                Text("S").strikethrough()
            }
            toggle("Underline", isOn: state.underline, shortcut: "u", action: controller.toggleUnderline) {
                Text("U").underline()
            }
        }
    }

    private func toggle(
        _ name: String,
        isOn: Bool,
        shortcut: KeyEquivalent?,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: 32, height: 30)
                .background(isOn ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(name)
        .modifier(OptionalShortcut(key: shortcut))
    }

    // MARK: Menus

    private var blockMenu: some View {
        Menu {
            blockButton("Text", kind: .paragraph)
            blockButton("Heading 1", kind: .heading1)
            blockButton("Heading 2", kind: .heading2)
            blockButton("Heading 3", kind: .heading3)
            blockButton("Quote", kind: .quote)
            blockButton("Code", kind: .code)
        } label: {
            menuLabel(blockName, width: 66)
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private func blockButton(_ name: String, kind: BlockKind) -> some View {
        Button {
            if state.textKind != kind { controller.setBlockKind(kind) }
        } label: {
            if state.textKind == kind {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    private var blockName: String {
        switch state.textKind {
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .quote: "Quote"
        case .code: "Code"
        default: "Text"
        }
    }

    private var fontMenu: some View {
        Menu {
            Button("System") { controller.setFont(nil) }
            ForEach(FontCatalog.choices) { choice in
                Button(choice.name) { controller.setFont(choice.id) }
            }
        } label: {
            menuLabel(state.font ?? "System", width: 56)
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private var sizeMenu: some View {
        Menu {
            ForEach(Self.sizes, id: \.self) { size in
                Button("\(Int(size))") { controller.setSize(size) }
            }
        } label: {
            menuLabel("\(Int(state.size))", width: 20)
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private func menuLabel(_ text: String, width: CGFloat) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .lineLimit(1)
                .frame(minWidth: width, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
    }

    // MARK: Lists

    private var listMenu: some View {
        Menu {
            listButton("Bullets", icon: "list.bullet", kind: .bullet)
            listButton("Dashes", icon: "list.dash", kind: .dash)
            listButton("Numbers", icon: "list.number", kind: .numbered)
            listButton("Checklist", icon: "checklist", kind: .checklist)
            Divider()
            Button(action: controller.indent) {
                Label("Indent", systemImage: "increase.indent")
            }
            Button(action: controller.outdent) {
                Label("Outdent", systemImage: "decrease.indent")
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "list.bullet")
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(state.isListItem ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .fixedSize()
        .accessibilityLabel("Lists")
        .help("Lists")
    }

    // Choosing the list an item is already in takes it out of the list.
    private func listButton(_ name: String, icon: String, kind: BlockKind) -> some View {
        Button {
            controller.setBlockKind(kind)
        } label: {
            Label(name, systemImage: state.blockKind == kind ? "checkmark" : icon)
        }
    }

    private func iconButton(_ name: String, icon: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 32, height: 30)
                .background(isOn ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(name)
    }

    // MARK: Links and inserting

    private var linkButton: some View {
        Menu {
            Button(state.link == nil ? "Add link" : "Edit link") {
                linkText = state.link ?? ""
                isAskingForLink = true
            }
            if state.link != nil {
                Button("Open link") {
                    if let url = controller.linkURLForOpening() { openURL(url) }
                }
                Button("Remove link", action: controller.removeLink)
            }
        } label: {
            Image(systemName: "link")
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .fixedSize()
        .accessibilityLabel("Link")
    }

    private var insertMenu: some View {
        Menu {
            Button("Table", systemImage: "tablecells", action: controller.insertTable)
            Button("Divider", systemImage: "minus", action: controller.insertDivider)
            if onInsertQuote != nil || onSaveSelectionAsQuote != nil {
                Divider()
            }
            if let onInsertQuote {
                Button("Quote from library", systemImage: "text.quote", action: onInsertQuote)
            }
            if let onSaveSelectionAsQuote {
                Button("Save selection as quote", systemImage: "square.and.arrow.down") {
                    if let text = controller.selectedPlainText() { onSaveSelectionAsQuote(text) }
                }
                .disabled(!state.hasSelection)
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .fixedSize()
        .accessibilityLabel("Insert")
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}
