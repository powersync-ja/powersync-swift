import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Full CRUD through `ModelContext`: updates land as PATCH and deletes as DELETE in
/// `ps_crud`, and empty model ids are minted and remapped robustly.
@Suite("ModelContext CRUD")
struct ModelContextCrudTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func updateIsCapturedAsPatchAndPersisted() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "crud-update", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )

        let id = UUID().uuidString.lowercased()
        let context = ModelContext(container)
        let note = Note(id: id, title: "hola", done: false, count: 1)
        context.insert(note)
        try context.save()
        try await #require(try await database.getNextCrudTransaction()).complete()

        note.title = "adiós"
        note.done = true
        try context.save()

        let maybePatch = try await database.getNextCrudTransaction()
        let patch = try #require(maybePatch)
        let entry = try #require(patch.crud.first)
        #expect(entry.op == .patch)
        #expect(entry.table == "note")
        #expect(entry.id == id)
        let opData = try #require(entry.opData)
        #expect(opData["title"] == "adiós")
        #expect(opData["done"] == "1")

        let fetched = try ModelContext(container).fetch(FetchDescriptor<Note>())
        let materialized = try #require(fetched.first)
        #expect(materialized.title == "adiós")
        #expect(materialized.done == true)
        #expect(materialized.count == 1)

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func deleteIsCapturedAndRowRemoved() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "crud-delete", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )

        let id = UUID().uuidString.lowercased()
        let context = ModelContext(container)
        let note = Note(id: id, title: "hola", done: false, count: 1)
        context.insert(note)
        try context.save()
        try await #require(try await database.getNextCrudTransaction()).complete()

        context.delete(note)
        try context.save()

        let maybeDelete = try await database.getNextCrudTransaction()
        let deletion = try #require(maybeDelete)
        let entry = try #require(deletion.crud.first)
        #expect(entry.op == .delete)
        #expect(entry.table == "note")
        #expect(entry.id == id)

        let fetched = try ModelContext(container).fetch(FetchDescriptor<Note>())
        #expect(fetched.isEmpty)

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func emptyIdIsMintedAndReregisteredInOriginalContext() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "crud-mint", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )

        let context = ModelContext(container)
        let note = Note(id: "", title: "hola", done: false, count: 0)
        context.insert(note)
        try context.save()

        let maybeTransaction = try await database.getNextCrudTransaction()
        let transaction = try #require(maybeTransaction)
        let entry = try #require(transaction.crud.first)
        #expect(!entry.id.isEmpty)

        let fetched = try ModelContext(container).fetch(FetchDescriptor<Note>())
        let materialized = try #require(fetched.first)
        #expect(materialized.id == entry.id)
        #expect(UUID(uuidString: materialized.id) != nil)

        // The save result reregisters the snapshot carrying the minted id, so the model
        // instance the app inserted must observe it too.
        #expect(note.id == entry.id)

        try await database.close()
    }
}
