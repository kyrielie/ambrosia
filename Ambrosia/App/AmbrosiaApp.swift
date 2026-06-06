import SwiftUI
import SwiftData

@main
struct AmbrosiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Book.self, Author.self, Fandom.self,
            Tag.self, Collection.self,
            ReadingState.self, ReadingGoal.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        // The actual window is managed by AppDelegate/NSWindowController.
        // We use WindowGroup only to satisfy the Scene requirement.
        WindowGroup {
            Color.clear.frame(width: 0, height: 0)
        }
        .modelContainer(sharedModelContainer)
    }
}
