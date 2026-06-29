import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Remote PowerSync changes (sync downloads) are re-injected into a
/// background `ModelContext` so SwiftData broadcasts them (`ModelContext.didSave`) and
/// `@Query` re-runs its fetch; the re-injection itself is echo-suppressed and never lands
/// back in the `ps_crud` upload queue.
@Suite("Reactivity")
struct ReactivityTests {
    /// Waits for a `ModelContext.didSave` notification from the observer's remote-author
    /// context that carries an identifier matching `key`, or fails after `timeout`.
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    private static func nextRemoteSave(
        carrying key: ModelContext.NotificationKey,
        timeout: Duration = .seconds(5)
    ) async throws -> [PersistentIdentifier] {
        let rawKey = key.rawValue
        return try await withThrowingTaskGroup(of: [PersistentIdentifier].self) { group in
            group.addTask {
                for await notification in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                    let author = (notification.object as? ModelContext)?.author
                    guard author == "powersync-remote" else { continue }
                    if let identifiers = notification.userInfo?[rawKey] as? [PersistentIdentifier],
                       !identifiers.isEmpty {
                        return identifiers
                    }
                }
                throw PowerSyncSwiftDataError.unimplemented("notification stream ended")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PowerSyncSwiftDataError.unimplemented("timed out waiting for remote didSave")
            }
            guard let result = try await group.next() else {
                throw PowerSyncSwiftDataError.unimplemented("no result")
            }
            group.cancelAll()
            return result
        }
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func remoteInsertIsBroadcastAndNotEchoed() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "reactivity-insert", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )
        let observer = PowerSyncChangeObserver(container: container, configuration: configuration)
        try await observer.start(observing: [Note.self])

        // Simulate a sync download: a row appears in PowerSync without going through
        // SwiftData.
        async let saved = Self.nextRemoteSave(carrying: .insertedIdentifiers)
        try await Task.sleep(for: .milliseconds(100))
        let id = UUID().uuidString.lowercased()
        // Writing to the internal ps_data__ table (not the view) is what a sync download
        // does: no INSTEAD OF trigger runs, so nothing is captured into ps_crud.
        _ = try await database.execute(
            sql: "INSERT INTO ps_data__note (id, data) VALUES (?, json_object('title', ?, 'done', 0, 'count', 7))",
            parameters: [id, "remota"]
        )

        let inserted = try await saved
        #expect(inserted.contains { $0.entityName == "Note" })

        // The re-injection must not produce upload queue entries.
        let crud = try await database.getNextCrudTransaction()
        #expect(crud == nil)

        // And a user context sees the new row.
        let fetched = try ModelContext(container).fetch(FetchDescriptor<Note>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "remota")
        #expect(fetched.first?.id == id)

        await observer.stop()
        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func remoteUpdateIsBroadcastAndNotEchoed() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "reactivity-update", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )

        // Local seed through SwiftData, upload entry completed.
        let id = UUID().uuidString.lowercased()
        let context = ModelContext(container)
        context.insert(Note(id: id, title: "local", done: false, count: 1))
        try context.save()
        try await #require(try await database.getNextCrudTransaction()).complete()

        let observer = PowerSyncChangeObserver(container: container, configuration: configuration)
        try await observer.start(observing: [Note.self])

        async let saved = Self.nextRemoteSave(carrying: .updatedIdentifiers)
        try await Task.sleep(for: .milliseconds(100))
        _ = try await database.execute(
            sql: "UPDATE ps_data__note SET data = json_set(data, '$.title', ?, '$.count', 9) WHERE id = ?",
            parameters: ["remota", id]
        )

        let updated = try await saved
        #expect(updated.contains { $0.entityName == "Note" })

        let crud = try await database.getNextCrudTransaction()
        #expect(crud == nil)

        let fetched = try ModelContext(container).fetch(FetchDescriptor<Note>())
        #expect(fetched.first?.title == "remota")
        #expect(fetched.first?.count == 9)

        await observer.stop()
        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func remoteDeleteIsBroadcastAndNotEchoed() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "reactivity-delete", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )

        let id = UUID().uuidString.lowercased()
        let context = ModelContext(container)
        context.insert(Note(id: id, title: "local", done: false, count: 1))
        try context.save()
        try await #require(try await database.getNextCrudTransaction()).complete()

        let observer = PowerSyncChangeObserver(container: container, configuration: configuration)
        try await observer.start(observing: [Note.self])

        async let saved = Self.nextRemoteSave(carrying: .deletedIdentifiers)
        try await Task.sleep(for: .milliseconds(100))
        _ = try await database.execute(sql: "DELETE FROM ps_data__note WHERE id = ?", parameters: [id])

        let deleted = try await saved
        #expect(deleted.contains { $0.entityName == "Note" })

        let crud = try await database.getNextCrudTransaction()
        #expect(crud == nil)

        let fetched = try ModelContext(container).fetch(FetchDescriptor<Note>())
        #expect(fetched.isEmpty)

        await observer.stop()
        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func localSavesDoNotLoopThroughTheObserver() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "reactivity-noloop", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [configuration]
        )
        let observer = PowerSyncChangeObserver(container: container, configuration: configuration)
        try await observer.start(observing: [Note.self])

        // A local save triggers the watch (the table changed), and the observer's
        // reconciliation may broadcast it; but it must not generate additional uploads
        // or rewrite rows.
        let id = UUID().uuidString.lowercased()
        let context = ModelContext(container)
        context.insert(Note(id: id, title: "local", done: false, count: 1))
        try context.save()

        let transaction = try #require(try await database.getNextCrudTransaction())
        #expect(transaction.crud.count == 1)
        try await transaction.complete()

        // Allow a few watch throttle windows for any (buggy) echo writes to surface.
        try await Task.sleep(for: .milliseconds(400))
        let crud = try await database.getNextCrudTransaction()
        #expect(crud == nil)

        await observer.stop()
        try await database.close()
    }
}
