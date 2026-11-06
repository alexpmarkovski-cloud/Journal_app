// The new quote window. Built for moving a lot of quotes quickly: "Save and add another" keeps
// the author and source, since the next quote is often from the same book.

import JournalCore
import SwiftUI

struct QuoteCaptureView: View {
    let capture: QuoteCapture
    let model: JournalModel

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var author = ""
    @State private var source = ""
    @State private var tags = ""
    @State private var savedCount = 0
    @FocusState private var isTextFocused: Bool

    init(capture: QuoteCapture, model: JournalModel) {
        self.capture = capture
        self.model = model
        _text = State(initialValue: capture.text)
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Quote", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($isTextFocused)
                }
                .themedRow()
                Section {
                    TextField("Author", text: $author)
                        .autocorrectionDisabled()
                    TextField("Source", text: $source)
                        .autocorrectionDisabled()
                    TextField("Tags, separated by commas", text: $tags)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } footer: {
                    if savedCount > 0 {
                        Text(savedCount == 1 ? "1 quote saved" : "\(savedCount) quotes saved")
                    }
                }
                .themedRow()
                Section {
                    Button("Save and add another", action: saveAndContinue)
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        .disabled(!canSave)
                }
                .themedRow()
            }
            .formStyle(.grouped)
            .themedBackground(.sheet)
            .navigationTitle("New quote")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(savedCount > 0 ? "Done" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 440)
        #endif
        .onAppear { isTextFocused = true }
    }

    private func save() {
        model.createQuote(
            text: text, author: author, source: source, tags: tags,
            sectionId: capture.sectionId, pageId: capture.pageId
        )
    }

    private func saveAndContinue() {
        save()
        savedCount += 1
        text = ""
        tags = ""
        isTextFocused = true
    }
}
