// Chooses the color of a notebook or section.
//
// A window of swatches and not a submenu, because Mac and iPhone menus can show their icons in
// one color only, which would make every choice look the same.

import JournalCore
import SwiftUI

struct ItemColorPicker: View {
    let name: String
    let current: ItemColor?
    let onChoose: (ItemColor?) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(ItemColor.allCases, id: \.self) { color in
                        swatch(color)
                    }
                }
                Button("No color") { choose(nil) }
                    .disabled(current == nil)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground(.sheet)
            .navigationTitle(name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.height(280)])
        #else
        .frame(width: 340, height: 240)
        #endif
    }

    private func swatch(_ color: ItemColor) -> some View {
        Button {
            choose(color)
        } label: {
            Circle()
                .fill(color.shade)
                .frame(width: 36, height: 36)
                .overlay {
                    // A ring as well as a check, since the check alone is hard to see on yellow.
                    if color == current {
                        Circle()
                            .stroke(.primary, lineWidth: 2)
                            .padding(-4)
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(color == current ? .isSelected : [])
    }

    private func choose(_ color: ItemColor?) {
        onChoose(color)
        dismiss()
    }
}
