// The main layout. NavigationSplitView shows three columns on Mac and automatically becomes
// drill-down screens on iPhone, so both devices share the same screens.

import SwiftUI

struct ContentView: View {
    @Bindable var model: JournalModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    // In the bottom corner of the window, so it stays put whether or not a page is open. A phone
    // shows one screen at a time and already has Add page, so it doesn't need this.
    private var showsNewPageButton: Bool {
        #if os(iOS)
        guard horizontalSizeClass != .compact else { return false }
        #endif
        return model.sidebarSelection != .quotes && model.selectedSection != nil
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $model.compactColumn) {
            SidebarView(model: model)
                .themedBackground(.sidebar)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            Group {
                if model.sidebarSelection == .quotes {
                    QuoteListView(model: model)
                } else {
                    PageListView(model: model)
                }
            }
            .themedBackground(.page)
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            Group {
                if model.sidebarSelection == .quotes {
                    QuoteDetailView(model: model)
                } else {
                    PageDetailView(model: model)
                }
            }
            // Filling the column first keeps the bar at the bottom when the page area is short.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsNewPageButton {
                    BottomBar(alignment: .trailing) {
                        Button("New page", systemImage: "square.and.pencil") { model.createPage() }
                            .labelStyle(.iconOnly)
                            .imageScale(.large)
                            .bottomBarButtonStyle()
                            .help("New page")
                    }
                }
            }
            .themedBackground(.page)
        }
        .sheet(item: $model.capture) { capture in
            QuoteCaptureView(capture: capture, model: model)
        }
        .task { await model.watchTree() }
        // Each of these restarts whenever the value in `id` changes.
        .task(id: model.selectedSectionId) { await model.watchPages() }
        .task(id: model.searchQuery) { await model.watchSearch() }
        // Here and not on the library screen, because on iPhone that screen stops watching as
        // soon as a quote opens on top of it, and quotes can be saved from anywhere.
        .task(id: model.quoteQuery) { await model.watchQuoteLibrary() }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}
