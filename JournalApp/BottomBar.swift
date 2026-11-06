// The strip along the bottom of a column, holding buttons like Add section and Add page. Columns
// share it so the buttons line up across the window.

import SwiftUI

struct BottomBar<Content: View>: View {
    @Environment(\.appTheme) private var theme
    var alignment = Alignment.leading
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 20, alignment: alignment)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(theme.background(.row).map(AnyShapeStyle.init) ?? AnyShapeStyle(.bar))
    }
}

extension View {
    // On Mac, a borderless button fades when the window isn't in front, unlike the Add section
    // menu next to it. A plain one matches it. On iPhone, borderless gives the usual tint.
    @ViewBuilder
    func bottomBarButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.plain)
        #else
        buttonStyle(.borderless)
        #endif
    }
}

