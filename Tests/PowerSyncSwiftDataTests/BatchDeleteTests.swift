import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Batch deletes translate to a single SQL DELETE (captured by PowerSync's triggers), and
/// erase() is intentionally unsupported: resetting local PowerSync data is
/// `disconnectAndClear()`'s job, and uploading DELETEs for every row would destroy server
/// data on what apps usually call during logout.
@Suite("Batch delete and erase")
struct BatchDeleteTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func batchDeleteWithPredicateRemovesMatchingRows() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "batch-batch", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )

        let context = ModelContext(container)
        for index in 0 ..< 6 {
            context.insert(Note(id: "n\(index)", title: "t\(index)", done: index % 2 == 0, count: index))
        }
        try context.save()
        try await #require(try await database.getNextCrudTransaction()).complete()

        try context.delete(model: Note.self, where: #Predicate { $0.count >= 3 })
        try context.save()

        let reader = ModelContext(container)
        let remaining = try reader.fetch(FetchDescriptor<Note>())
        #expect(Set(remaining.map(\.id)) == ["n0", "n1", "n2"])

        // The batch delete is captured for upload.
        let transaction = try #require(try await database.getNextCrudTransaction())
        let deletes = transaction.crud.filter { $0.op == .delete && $0.table == "note" }
        #expect(Set(deletes.map(\.id)) == ["n3", "n4", "n5"])

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func eraseIsUnsupportedInFavorOfDisconnectAndClear() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "batch-erase", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )
        _ = container

        let store = try PowerSyncDataStore(configuration, migrationPlan: nil)
        #expect(throws: DataStoreError.unsupportedFeature) {
            try store.erase()
        }

        try await database.close()
    }
}
