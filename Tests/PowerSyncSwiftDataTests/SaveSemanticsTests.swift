import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Save-request semantics: statement ordering supports the delete+insert "replace by id"
/// pattern in one save, and the id of a saved model is immutable (the row is addressed by
/// its persistent identifier, and mutating the property fails loudly instead of silently
/// targeting nothing).
@Suite("Save semantics")
struct SaveSemanticsTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func deleteAndInsertWithSameIdInOneSaveReplacesTheRow() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "save-replace", database: database)]
        )

        let context = ModelContext(container)
        let original = Note(id: "x", title: "vieja", done: false, count: 1)
        context.insert(original)
        try context.save()
        try await #require(try await database.getNextCrudTransaction()).complete()

        // Replace: delete the old model and insert a new one with the SAME id in one save.
        context.delete(original)
        context.insert(Note(id: "x", title: "nueva", done: true, count: 2))
        try context.save()

        let reader = ModelContext(container)
        let fetched = try reader.fetch(FetchDescriptor<Note>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == "x")
        #expect(fetched.first?.title == "nueva")

        // The upload queue saw the delete BEFORE the insert.
        let transaction = try #require(try await database.getNextCrudTransaction())
        let ops = transaction.crud.filter { $0.id == "x" }.map(\.op)
        #expect(ops == [.delete, .put])

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func mutatingTheIdOfASavedModelFailsLoudly() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "save-id-mutation", database: database)]
        )

        let context = ModelContext(container)
        let note = Note(id: "original", title: "t", done: false, count: 0)
        context.insert(note)
        try context.save()

        note.id = "renamed"
        note.title = "cambiada"
        #expect(throws: (any Error).self) {
            try context.save()
        }

        // The stored row is untouched under its original id.
        let stored = try await database.get(
            sql: "SELECT title FROM note WHERE id = ?",
            parameters: ["original"]
        ) { try $0.getString(index: 0) }
        #expect(stored == "t")

        try await database.close()
    }
}
