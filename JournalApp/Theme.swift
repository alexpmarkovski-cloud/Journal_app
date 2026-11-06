// The app's themes and how they reach every screen.
//
// Light and dark use the system's own colors. Midnight is dark mode with navy painted behind
// the content, so text, menus and system controls all still work out their own colors. Adding a
// theme means adding a case here and giving it colors.

import JournalCore
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark, midnight

    var id: Self { self }

    var name: String {
        switch self {
        case .system: "Match system"
        case .light: "Light"
        case .dark: "Dark"
        case .midnight: "Midnight navy"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .midnight: .dark
        }
    }

    // The color behind a part of the screen. Nil keeps the system's own.
    func background(_ surface: ThemeSurface) -> Color? {
        guard self == .midnight else { return nil }
        switch surface {
        case .sidebar: return Color(red: 0.043, green: 0.078, blue: 0.149)
        case .page: return Color(red: 0.059, green: 0.106, blue: 0.200)
        case .sheet: return Color(red: 0.059, green: 0.106, blue: 0.200)
        case .row: return Color(red: 0.094, green: 0.153, blue: 0.275)
        }
    }
}

enum ThemeSurface {
    case sidebar, page, sheet, row
}

extension EnvironmentValues {
    @Entry var appTheme = AppTheme.system
}

// Wraps a window's content, so every screen and sheet inside it gets the chosen theme.
struct ThemedRoot<Content: View>: View {
    @AppStorage("appTheme") private var theme = AppTheme.system
    @ViewBuilder var content: Content

    var body: some View {
        content
            .environment(\.appTheme, theme)
            #if os(macOS)
            // Set on the app rather than with preferredColorScheme, because on Mac that doesn't
            // reliably go back to following the system once it has been set.
            .onChange(of: theme, initial: true) {
                NSApp.appearance = theme.colorScheme.map { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) } ?? nil
            }
            #else
            // Set on the window for the same reason. With preferredColorScheme, an open sheet
            // stays dark after switching to Light.
            .background(WindowStyle(colorScheme: theme.colorScheme))
            #endif
    }
}

#if os(iOS)
// An invisible view, there to reach the window it's in.
private struct WindowStyle: UIViewRepresentable {
    let colorScheme: ColorScheme?

    func makeUIView(context: Context) -> StyleSetter { StyleSetter() }

    func updateUIView(_ view: StyleSetter, context: Context) {
        view.style = switch colorScheme {
        case .dark: .dark
        case .light: .light
        default: .unspecified
        }
        view.apply()
    }

    final class StyleSetter: UIView {
        var style = UIUserInterfaceStyle.unspecified

        // The view isn't in a window yet when it's first made.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            window?.overrideUserInterfaceStyle = style
        }
    }
}
#endif

private struct ThemedBackground: ViewModifier {
    @Environment(\.appTheme) private var theme
    let surface: ThemeSurface

    // Both values are always applied, rather than choosing between two versions of the view.
    // Switching versions would rebuild the screen, closing any page that's open.
    func body(content: Content) -> some View {
        let color = theme.background(surface)
        content
            .scrollContentBackground(color == nil && !paintsSystemBackground ? .automatic : .hidden)
            // A short view, like "Choose a page", would otherwise only paint behind itself.
            .frame(maxWidth: fillsColumn ? .infinity : nil, maxHeight: fillsColumn ? .infinity : nil)
            .background(color ?? systemBackground)
            #if os(macOS)
            // The strip across the top of a Mac window has its own see-through gray. Hiding it
            // lets the navy underneath show, and "automatic" leaves the other themes alone.
            .toolbarBackgroundVisibility(color == nil ? .automatic : .hidden, for: .windowToolbar)
            #endif
    }

    private var fillsColumn: Bool {
        surface == .sidebar || surface == .page
    }

    // On iPhone, the search box's strip needs the same gray as the lists it sits above.
    private var paintsSystemBackground: Bool {
        #if os(iOS)
        surface == .sidebar
        #else
        false
        #endif
    }

    private var systemBackground: Color {
        #if os(iOS)
        surface == .sidebar ? Color(.systemGroupedBackground) : .clear
        #else
        .clear
        #endif
    }
}

private struct ThemedRow: ViewModifier {
    @Environment(\.appTheme) private var theme
    let surface: ThemeSurface

    func body(content: Content) -> some View {
        #if os(iOS)
        content.listRowBackground(theme.background(surface))
        #else
        content
        #endif
    }
}

extension View {
    func themedBackground(_ surface: ThemeSurface) -> some View {
        modifier(ThemedBackground(surface: surface))
    }

    // List rows have their own background, which doesn't follow the list's on iPhone.
    func themedRow(_ surface: ThemeSurface = .row) -> some View {
        modifier(ThemedRow(surface: surface))
    }
}

// MARK: Item colors

extension ItemColor {
    // System colors, which already adjust their shade for light and dark backgrounds. Teal is
    // the exception, because the system's looks the same as cyan on a dark background.
    var shade: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: Color(red: 0.0, green: 0.58, blue: 0.53)
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    var name: String { rawValue.capitalized }
}

// A notebook, group or section's icon. A color fills in the same shape.
struct ItemIcon: View {
    let kind: TreeItemKind
    let color: ItemColor?

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color?.shade ?? .secondary)
            .frame(width: 20)
    }

    private var symbol: String {
        let isFilled = color != nil
        switch kind {
        case .notebook: return isFilled ? "book.closed.fill" : "book.closed"
        case .group: return "folder"
        case .section: return isFilled ? "doc.text.fill" : "doc.text"
        }
    }
}
