import SwiftData
import SwiftUI

@main
struct SwiftDataDemoApp: App {
    @State private var system = SystemManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(system)
        }
        // Every @Query and @Environment(\.modelContext) in the app reads and writes
        // through the PowerSync-backed container.
        .modelContainer(system.container)
    }
}
