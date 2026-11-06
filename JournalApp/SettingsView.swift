// The app's settings. On Mac it's the usual Settings window, and on iPhone a sheet from the
// sidebar. Settings belong to each device, so the Mac and iPhone can use different themes.

import SwiftUI

struct SettingsView: View {
    @AppStorage("appTheme") private var theme = AppTheme.system
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        themePicker
            .padding(24)
            .frame(width: 480)
            .themedBackground(.sheet)
        #else
        NavigationStack {
            ScrollView {
                themePicker
                    .padding(20)
            }
            .themedBackground(.sheet)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #endif
    }

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                ForEach(AppTheme.allCases) { option in
                    Button {
                        theme = option
                    } label: {
                        ThemeTile(theme: option, isSelected: option == theme)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == theme ? .isSelected : [])
                }
            }
        }
    }
}

// A small drawing of the app in a theme. Its colors are written out, because it shows a theme
// that isn't the current one.
private struct ThemeTile: View {
    let theme: AppTheme
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            preview
                .frame(height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: isSelected ? 3 : 1)
                }
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
                Text(theme.name)
                    .font(.subheadline)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var preview: some View {
        switch theme {
        case .system:
            // Half light and half dark, for following whichever the device is using.
            HStack(spacing: 0) {
                miniature(sidebar: lightSidebar, page: .white, text: .black)
                miniature(sidebar: darkSidebar, page: darkPage, text: .white)
            }
        case .light:
            miniature(sidebar: lightSidebar, page: .white, text: .black)
        case .dark:
            miniature(sidebar: darkSidebar, page: darkPage, text: .white)
        case .midnight:
            miniature(
                sidebar: theme.background(.sidebar) ?? darkSidebar,
                page: theme.background(.page) ?? darkPage,
                text: .white
            )
        }
    }

    private let lightSidebar = Color(white: 0.93)
    private let darkSidebar = Color(white: 0.17)
    private let darkPage = Color(white: 0.08)

    private func miniature(sidebar: Color, page: Color, text: Color) -> some View {
        HStack(spacing: 0) {
            sidebar
                .frame(maxWidth: 40)
                .overlay(alignment: .topLeading) { lines(count: 3, color: text, widths: [24, 18, 22]) }
            page
                .overlay(alignment: .topLeading) { lines(count: 4, color: text, widths: [34, 44, 38, 26]) }
                // The half-size drawing for "Match system" is narrower than the longest line.
                .clipped()
        }
    }

    private func lines(count: Int, color: Color, widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(0.45))
                    .frame(width: widths[index], height: 4)
            }
        }
        .padding(8)
    }
}
