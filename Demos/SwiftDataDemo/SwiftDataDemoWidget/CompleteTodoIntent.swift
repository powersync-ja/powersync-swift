import AppIntents
import Foundation
import PowerSync
import PowerSyncSwiftData
import SwiftData

/// Marks a todo as completed — **from the widget's own process**.
///
/// Interactive widget buttons run their App Intent in the widget extension by default;
/// this intent opens its own database over the shared App Group file and writes through
/// a regular `ModelContext`. The write persists immediately, lands in the shared upload
/// queue (the app's sync client uploads it), and the cross-process change signal updates
/// the app's `@Query` views live if the app is running.
struct CompleteTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Todo"
    static let description = IntentDescription("Marks a todo as completed.")

    @Parameter(title: "Todo ID")
    var todoId: String

    init() {}

    init(todoId: String) {
        self.todoId = todoId
    }

    func perform() async throws -> some IntentResult {
        let database = try SharedDatabase.openDatabase()
        defer { Task { try? await database.close() } }

        let container = try ModelContainer(
            for: SwiftData.Schema(SharedDatabase.models),
            configurations: [PowerSyncDataStoreConfiguration(
                name: "powersync-widget-intent",
                database: database
            )]
        )
        let context = ModelContext(container)
        let id = todoId
        let descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.id == id })
        if let todo = try context.fetch(descriptor).first {
            todo.completed = true
            try context.save()
        }
        return .result()
    }
}
