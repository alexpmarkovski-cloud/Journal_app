// The search box used in the sidebar and the quote library.
//
// SwiftUI's built-in `.searchable` isn't used here. On iPhone, while its search is active, a
// screen opened from the results stops receiving updates: typing appeared on screen and was
// never saved. A plain text field has no separate search mode, so that can't happen. It also
// means results are still there when coming back from one.

import SwiftUI

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    // Jumps to the field from anywhere on a Mac.
    var shortcut: KeyboardShortcut?
    // Lets the screen around it move the keyboard here.
    var focus: FocusState<Bool>.Binding?

    @FocusState private var ownFocus: Bool

    private var isFocused: FocusState<Bool>.Binding { focus ?? $ownFocus }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused(isFocused)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #else
                .onExitCommand { text = "" }
                #endif
            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .background {
            if let shortcut {
                Button("Search") { isFocused.wrappedValue = true }
                    .keyboardShortcut(shortcut)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
