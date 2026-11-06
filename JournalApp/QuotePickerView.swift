// Chooses a quote to place in the open page.

import JournalCore
import SwiftUI

struct QuotePickerView: View {
    let model: JournalModel
    let onPick: (Quote) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var quotes: [Quote] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchField(prompt: "Text, author or tag", text: $search)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                if quotes.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("No quotes yet", systemImage: "text.quote")
                            .frame(maxHeight: .infinity)
                    } else {
                        ContentUnavailableView.search(text: search)
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    List(quotes) { quote in
                        Button {
                            onPick(quote)
                            dismiss()
                        } label: {
                            QuoteRow(quote: quote)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .themedRow()
                    }
                }
            }
            .themedBackground(.sheet)
            .navigationTitle("Place a quote")
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
        .frame(minWidth: 460, minHeight: 440)
        #endif
        .task(id: search) {
            quotes = model.quotesToPick(matching: search)
        }
    }
}
