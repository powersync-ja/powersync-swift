import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// The read-only path for app extensions and widgets. The same store fetches
/// normally but refuses writes, so a widget can render synced data without competing for
/// the upload queue or risking suspension mid-write.
@Suite("Read-only store")
struct ReadOnlyStoreTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func readOnlyStoreFetchesButRefusesWrites() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(
            name: "readonly-store",
            database: database,
            readOnly: true
        )
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )

        // Data that arrived via sync.
        _ = try await database.execute(
            sql: "INSERT INTO ps_data__note (id, data) VALUES (?, json_object('title', ?, 'done', 1, 'count', 4))",
            parameters: ["w1", "widget"]
        )

        let context = ModelContext(container)
        let fetched = try context.fetch(FetchDescriptor<Note>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "widget")

        // Writes are refused and nothing reaches the upload queue.
        context.insert(Note(id: "w2", title: "nope", done: false, count: 0))
        #expect(throws: (any Error).self) {
            try context.save()
        }
        let crud = try await database.getNextCrudTransaction()
        #expect(crud == nil)

        try await database.close()
    }
}
