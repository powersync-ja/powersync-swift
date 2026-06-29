import Foundation
import PowerSync
import PowerSyncSwiftData
import SwiftData
import WidgetKit

/// A value snapshot of a pending todo. Timeline entries must not hold `@Model` instances
/// (they outlive the `ModelContainer` the models were fetched from), so the provider copies
/// the fetched values into this plain struct.
struct PendingTodoItem: Identifiable {
    let id: String
    let descriptionText: String
}

struct PendingTodosEntry: TimelineEntry {
    let date: Date
    let todos: [PendingTodoItem]
    let pendingCount: Int

    static let placeholder = PendingTodosEntry(
        date: .now,
        todos: [
            PendingTodoItem(id: "1", descriptionText: "Buy groceries"),
            PendingTodoItem(id: "2", descriptionText: "Water the plants"),
        ],
        pendingCount: 2
    )
}

/// Reads the first pending todos straight from the synced PowerSync database.
///
/// The provider opens its OWN `PowerSyncDatabase` over the SAME file in the App Group
/// container the app syncs into. It never calls `connect()` (the app owns the sync
/// connection) and the store is configured with `readOnly: true`, so any accidental write
/// is refused: reads stay short and the extension cannot be suspended mid-write
/// (`0xDEAD10CC`). The database is closed as soon as the fetch completes.
struct PendingTodosProvider: TimelineProvider {
    func placeholder(in _: Context) -> PendingTodosEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (PendingTodosEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        Task {
            completion(await loadEntry())
        }
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<PendingTodosEntry>) -> Void) {
        Task {
            let entry = await loadEntry()
            // Ask the system to refresh in 15 minutes; the system also reloads timelines
            // on its own schedule (and whenever the app calls into WidgetCenter).
            let timeline = Timeline(
                entries: [entry],
                policy: .after(.now.addingTimeInterval(15 * 60))
            )
            completion(timeline)
        }
    }

    private func loadEntry() async -> PendingTodosEntry {
        do {
            let database = try SharedDatabase.openDatabase()
            defer {
                Task {
                    try? await database.close()
                }
            }

            let configuration = PowerSyncDataStoreConfiguration(
                name: "powersync-widget",
                database: database,
                readOnly: true
            )
            let container = try ModelContainer(
                for: SwiftData.Schema(SharedDatabase.models),
                configurations: [configuration]
            )
            let context = ModelContext(container)

            var descriptor = FetchDescriptor<Todo>(
                predicate: #Predicate { !$0.completed },
                sortBy: [SortDescriptor(\.descriptionText)]
            )
            let pendingCount = try context.fetchCount(descriptor)
            descriptor.fetchLimit = 5
            let todos = try context.fetch(descriptor).map {
                PendingTodoItem(id: $0.id, descriptionText: $0.descriptionText)
            }

            return PendingTodosEntry(date: .now, todos: todos, pendingCount: pendingCount)
        } catch {
            // The database may not exist yet (the app has never run or never synced).
            return PendingTodosEntry(date: .now, todos: [], pendingCount: 0)
        }
    }
}
