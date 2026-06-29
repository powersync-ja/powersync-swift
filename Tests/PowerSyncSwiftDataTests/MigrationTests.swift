import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Schema evolution. PowerSync tables are views over JSON and the local database is a
/// cache of synced data, so most "migrations" are absorbed structurally: new models and
/// columns appear when the database opens with the new derived schema, old rows read NULL
/// for added columns, and keys of removed properties are simply ignored. These tests pin
/// the behaviors that need code: defaults for added required properties, a descriptive
/// error (not a trap) when a required value is missing without a default, and the explicit
/// rejection of SwiftData migration plans.
@Suite("Schema evolution")
struct MigrationTests {
    static func makeMigratedDatabase() async throws -> any PowerSyncDatabaseProtocol {
        let database = PowerSyncDatabase(
            schema: PowerSync.Schema(tables: [
                Table(name: "migrated", columns: [.text("name"), .integer("rating")]),
                Table(name: "strict", columns: [.integer("score")]),
            ]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()
        return database
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func addedOptionalPropertiesReadNilForOldRows() async throws {
        let database = try await TestDatabases.makeTypeMixDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([TypeMix.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "migration-optional", database: database)]
        )

        // An "old" row stored before the optional properties existed: its JSON simply
        // lacks those keys.
        _ = try await database.execute(
            sql: """
            INSERT INTO ps_data__type_mix (id, data) VALUES (?, json_object(
                'text', 'old', 'integer', 1, 'integer64', 1, 'integer32', 1, 'flag', 0,
                'fraction', 1.5, 'fraction32', 1.5, 'stamp', 1700000000.0,
                'payload', 'AQI=', 'token', ?, 'mood', 'sunny', 'level', 1,
                'geo', '{"lat":0,"lon":0}'
            ))
            """,
            parameters: ["old-row", UUID().uuidString]
        )

        let fetched = try ModelContext(container).fetch(FetchDescriptor<TypeMix>())
        let model = try #require(fetched.first)
        #expect(model.text == "old")
        #expect(model.subtitle == nil)
        #expect(model.optionalNumber == nil)
        #expect(model.optionalStamp == nil)
        #expect(model.optionalPayload == nil)

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func addedRequiredPropertyUsesItsDefaultForOldRows() async throws {
        let database = try await Self.makeMigratedDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([Migrated.self, Strict.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "migration-default", database: database)]
        )

        // An "old" row stored before `rating` existed.
        _ = try await database.execute(
            sql: "INSERT INTO ps_data__migrated (id, data) VALUES (?, json_object('name', ?))",
            parameters: ["m1", "vieja"]
        )

        let fetched = try ModelContext(container).fetch(FetchDescriptor<Migrated>())
        let model = try #require(fetched.first)
        #expect(model.name == "vieja")
        #expect(model.rating == 5)

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func missingRequiredValueWithoutDefaultThrowsDescriptively() async throws {
        let database = try await Self.makeMigratedDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([Migrated.self, Strict.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "migration-strict", database: database)]
        )

        _ = try await database.execute(
            sql: "INSERT INTO ps_data__strict (id, data) VALUES (?, json_object('other', 1))",
            parameters: ["s1"]
        )

        // Materializing a required property with no stored value and no default cannot
        // succeed; it must surface as a thrown error, never a trap inside SwiftData.
        #expect(throws: (any Error).self) {
            _ = try ModelContext(container).fetch(FetchDescriptor<Strict>())
        }

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func removedPropertyKeysAreIgnored() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "migration-removed", database: database)]
        )

        // A row written by an older app version whose model had an extra `legacy`
        // property: the key survives in the JSON and must be ignored.
        _ = try await database.execute(
            sql: """
            INSERT INTO ps_data__note (id, data)
            VALUES (?, json_object('title', 'hola', 'done', 1, 'count', 2, 'legacy', 'x'))
            """,
            parameters: ["n1"]
        )

        let fetched = try ModelContext(container).fetch(FetchDescriptor<Note>())
        let note = try #require(fetched.first)
        #expect(note.title == "hola")
        #expect(note.count == 2)

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func newModelsWorkOnAnExistingDatabaseFile() async throws {
        // Version 1 of the app: only Note, on a file-backed database.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)/powersync.db").path
        let v1 = PowerSyncDatabase(
            schema: try PowerSyncSchema(for: [Note.self]),
            dbFilename: path,
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await v1.disconnectAndClear()
        let containerV1 = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "migration-v1", database: v1)]
        )
        let contextV1 = ModelContext(containerV1)
        contextV1.insert(Note(id: "n1", title: "v1", done: false, count: 1))
        try contextV1.save()
        try await v1.close()

        // Version 2 adds the Migrated model: reopening with the new derived schema
        // regenerates the views; old data is intact and the new table is usable.
        let v2 = PowerSyncDatabase(
            schema: try PowerSyncSchema(for: [Note.self, Migrated.self]),
            dbFilename: path,
            logger: DefaultLogger(minSeverity: .warning)
        )
        let containerV2 = try ModelContainer(
            for: SwiftData.Schema([Note.self, Migrated.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "migration-v2", database: v2)]
        )
        let contextV2 = ModelContext(containerV2)
        let notes = try contextV2.fetch(FetchDescriptor<Note>())
        #expect(notes.first?.title == "v1")
        contextV2.insert(Migrated(id: "m1", name: "nueva", rating: 9))
        try contextV2.save()
        let migrated = try contextV2.fetch(FetchDescriptor<Migrated>())
        #expect(migrated.first?.rating == 9)

        try await v2.close(deleteDatabase: true)
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func migrationPlansAreRejected() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let configuration = PowerSyncDataStoreConfiguration(
            name: "migration-plan",
            database: database,
            schema: SwiftData.Schema([Note.self])
        )
        #expect(throws: PowerSyncSwiftDataError.self) {
            _ = try PowerSyncDataStore(configuration, migrationPlan: NoopMigrationPlan.self)
        }
        try await database.close()
    }
}
