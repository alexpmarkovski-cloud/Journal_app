// The app's starting point. Opens the database and shows the main window.

import JournalCore
import SwiftUI

@main
struct JournalApp: App {
    // Nil if the database couldn't be opened, in which case the app shows a message and
    // doesn't touch anything.
    @State private var model: JournalModel? = {
        guard let database = try? (usesThrowawayJournal ? AppDatabase.inMemory() : AppDatabase.openDefault()) else {
            return nil
        }
        #if DEBUG
        // Lets a test run start with sample notebooks, without any tapping.
        if CommandLine.arguments.contains("--seed-sample"), (try? database.tree().isEmpty) == true {
            try? database.addSampleData()
        }
        #endif
        return JournalModel(database: database, defaults: defaults)
    }()

    // Lets a test run use a throwaway journal, leaving the real one untouched.
    private static var usesThrowawayJournal: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--in-memory")
        #else
        false
        #endif
    }

    // A throwaway journal also keeps its own settings, so it can't change the real journal's
    // theme or which notebook it opens on.
    private static let defaults = usesThrowawayJournal ? UserDefaults(suiteName: "throwaway-journal") ?? .standard : .standard

    var body: some Scene {
        WindowGroup {
            ThemedRoot {
                if let model {
                    ContentView(model: model)
                } else {
                    ContentUnavailableView(
                        "Couldn't open your journal",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Your notes haven't been changed. Quit the app and open it again.")
                    )
                }
            }
            .defaultAppStorage(Self.defaults)
        }
        #if os(macOS)
        // Gives the Mac its usual Settings item in the app menu, and Command-comma.
        Settings {
            ThemedRoot {
                SettingsView()
            }
            .defaultAppStorage(Self.defaults)
        }
        #endif
    }
}
