import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// A flat `@Model` round-trips through a `ModelContainer` backed by `PowerSyncDataStore`
/// over an in-memory PowerSync database, writes are captured in the `ps_crud` upload
/// queue, and materialization happens by property name.
@Suite("Snapshot materialization")
struct MaterializationTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func insertSaveCapturesCrudAndFetchesInAnotherContext() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "materialization-store", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )

        let id = UUID().uuidString.lowercased()
        let context = ModelContext(container)
        context.insert(Note(id: id, title: "hola", done: true, count: 3))
        try context.save()

        // The write must have been captured in PowerSync's upload queue.
        let maybeTransaction = try await database.getNextCrudTransaction()
        let transaction = try #require(maybeTransaction)
        #expect(transaction.crud.count == 1)
        let entry = try #require(transaction.crud.first)
        #expect(entry.op == .put)
        #expect(entry.table == "note")
        #expect(entry.id == id)
        let opData = try #require(entry.opData)
        #expect(opData["title"] == "hola")
        #expect(opData["done"] == "1")
        #expect(opData["count"] == "3")

        // A different context materializes the model through the store with correct values
        // and the same id, without trapping in "Failed to materialize".
        let otherContext = ModelContext(container)
        let fetched = try otherContext.fetch(FetchDescriptor<Note>())
        #expect(fetched.count == 1)
        let materialized = try #require(fetched.first)
        #expect(materialized.id == id)
        #expect(materialized.title == "hola")
        #expect(materialized.done == true)
        #expect(materialized.count == 3)

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func materializationMatchesSnapshotValuesByPropertyName() async throws {
        let database = try await TestDatabases.makeNoteDatabase()

        // Seed a row directly through PowerSync, bypassing the save path.
        let id = UUID().uuidString.lowercased()
        _ = try await database.execute(
            sql: "INSERT INTO note (id, title, done, count) VALUES (?, ?, ?, ?)",
            parameters: [id, "hola", Int64(1), Int64(3)]
        )

        // Control: with property-name-aligned snapshot keys the value arrives. This proves
        // the fetch pipeline works, so any difference below is attributable to the key name.
        let alignedConfiguration = PowerSyncDataStoreConfiguration(name: "materialization-aligned", database: database)
        let alignedContainer = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [alignedConfiguration]
        )
        let aligned = try ModelContext(alignedContainer).fetch(FetchDescriptor<Note>())
        let alignedFirst = try #require(aligned.first)
        #expect(alignedFirst.title == "hola")
        try await database.close()

        // Experiment: a store that hands SwiftData snapshots carrying the stored title
        // under the key "name" instead of the property name "title". SwiftData's model
        // decoder looks properties up by name and traps on the unknown key
        // ("Cannot find name because it is not known to this model type" in ModelCoders),
        // so the proof asserts process death in a child process. If this ever *stops*
        // failing, snapshot materialization is no longer by property name and the store's
        // core assumption must be revisited.
        #if os(macOS)
        await #expect(processExitsWith: .failure) {
            let database = try await TestDatabases.makeNoteDatabase()
            let configuration = PowerSyncDataStoreConfiguration(name: "materialization-misaligned", database: database)
            configuration._testFetchKeyTransform = { $0 == "title" ? "name" : $0 }
            let container = try ModelContainer(
                for: SwiftData.Schema([Note.self]),
                configurations: [configuration]
            )
            _ = try await database.execute(
                sql: "INSERT INTO note (id, title, done, count) VALUES (?, ?, ?, ?)",
                parameters: ["misaligned-row", "hola", Int64(1), Int64(3)]
            )
            _ = try ModelContext(container).fetch(FetchDescriptor<Note>())
        }
        #endif
    }
}
