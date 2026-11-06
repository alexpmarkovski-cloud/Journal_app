// Chooses where the search box looks: everything, or one notebook, section group or section.
//
// A list and not a menu, because a real journal can nest several levels deep with dozens of
// sections, and that's hard to get through in nested menus on an iPhone.

import JournalCore
import SwiftUI

struct SearchScopePicker: View {
    let model: JournalModel
    let onChoose: () -> Void

    @Environment(\.dismiss) private var dismiss

    // Opens at the place being searched, or else where the journal is open now.
    private var startingRow: UUID? {
        if case .item(let ref) = model.searchScope { return ref.id }
        return model.selectedSectionId
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    row(name: "Everything", depth: 0, scope: .everything) {
                        Image(systemName: "tray.full")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                    }
                    ForEach(model.tree.allRows) { item in
                        row(name: item.name, depth: item.depth, scope: .item(item.ref)) {
                            ItemIcon(kind: item.ref.kind, color: item.color)
                        }
                        .id(item.id)
                    }
                }
                .themedBackground(.sheet)
                .onAppear {
                    if let startingRow { proxy.scrollTo(startingRow, anchor: .center) }
                }
            }
            .navigationTitle("Search in")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 440)
        #endif
    }

    private func row(name: String, depth: Int, scope: SearchScope, @ViewBuilder icon: () -> some View) -> some View {
        Button {
            model.searchScope = scope
            dismiss()
            onChoose()
        } label: {
            HStack(spacing: 8) {
                icon()
                Text(name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.searchScope == scope {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.leading, CGFloat(depth) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedRow()
    }
}
