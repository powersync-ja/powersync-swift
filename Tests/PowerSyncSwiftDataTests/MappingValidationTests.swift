import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Early, descriptive failure for configuration mistakes that previously surfaced as
/// cryptic SQL errors mid-fetch (or hangs): mapping validated against the actual database,
/// table-name collisions, conflicting registrations from a second store, unsupported model
/// inheritance, ephemeral attributes, and out-of-range integers from the backend.
@Suite("Mapping validation and hardening")
struct MappingValidationTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func missingTableFailsContainerCreationDescriptively() async throws {
        // PowerSync schema with NO note table.
        let database = PowerSyncDatabase(
            schema: PowerSync.Schema(tables: [Table(name: "unrelated", columns: [.text("x")])]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()

        let configuration = PowerSyncDataStoreConfiguration(name: "validate-table", database: database)
        #expect(throws: (any Error).self) {
            _ = try ModelContainer(
                for: SwiftData.Schema([Note.self]),
                configurations: [configuration]
            )
        }
        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func missingColumnFailsContainerCreationDescriptively() async throws {
        // note table exists but lacks the `count` column.
        let database = PowerSyncDatabase(
            schema: PowerSync.Schema(tables: [
                Table(name: "note", columns: [.text("title"), .integer("done")]),
            ]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()

        let configuration = PowerSyncDataStoreConfiguration(name: "validate-column", database: database)
        do {
            _ = try ModelContainer(
                for: SwiftData.Schema([Note.self]),
                configurations: [configuration]
            )
            Issue.record("container creation should have failed")
        } catch {
            #expect(String(describing: error).contains("count"))
        }
        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func tableNameCollisionsAreRejected() throws {
        #expect(throws: PowerSyncSwiftDataError.self) {
            _ = try SchemaMapper(
                schema: SwiftData.Schema([Playlist.self, Song.self]),
                tableNameForEntity: { _ in "same_table" }
            )
        }
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func conflictingEntityShapesAcrossStoresAreRejected() async throws {
        // First store registers Note with the default table name.
        let first = try await TestDatabases.makeNoteDatabase()
        let firstContainer = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "registry-a", database: first)]
        )
        _ = firstContainer

        // A second store maps the SAME entity to a different table: registering it would
        // silently corrupt whichever store loses the registry race, so it must fail.
        let second = PowerSyncDatabase(
            schema: PowerSync.Schema(tables: [
                Table(name: "renamed_note", columns: [.text("title"), .integer("done"), .integer("count")]),
            ]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await second.disconnectAndClear()
        let conflicting = PowerSyncDataStoreConfiguration(
            name: "registry-b",
            database: second,
            tableNameForEntity: { _ in "renamed_note" }
        )
        #expect(throws: (any Error).self) {
            _ = try ModelContainer(
                for: SwiftData.Schema([Note.self]),
                configurations: [conflicting]
            )
        }

        try await first.close()
        try await second.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func modelInheritanceIsRejectedClearly() throws {
        let id = SwiftData.Schema.Attribute(name: "id", valueType: String.self)
        let parent = SwiftData.Schema.Entity("Base")
        parent.storedProperties = [id]
        let child = SwiftData.Schema.Entity("Child")
        child.storedProperties = [SwiftData.Schema.Attribute(name: "id", valueType: String.self)]
        child.superentityName = "Base"
        parent.subentities = [child]

        do {
            _ = try SchemaMapper(
                schema: SwiftData.Schema(parent, child),
                tableNameForEntity: PowerSyncDataStoreConfiguration.defaultTableName(forEntityName:)
            )
            Issue.record("inheritance should be rejected")
        } catch {
            #expect(String(describing: error).contains("inheritance"))
        }
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func ephemeralAttributesNeverReachPowerSync() async throws {
        let database = PowerSyncDatabase(
            schema: try PowerSyncSchema(for: [EphemeralNote.self]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()

        // The derived schema has no column for the ephemeral attribute.
        let derived = try PowerSyncSchema(for: [EphemeralNote.self])
        let table = try #require(derived.tables.first { $0.name == "ephemeral_note" })
        #expect(!table.columns.contains { $0.name == "draft" })

        let container = try ModelContainer(
            for: SwiftData.Schema([EphemeralNote.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "ephemeral", database: database)]
        )
        let context = ModelContext(container)
        context.insert(EphemeralNote(id: "e1", title: "hola", draft: "no me subas"))
        try context.save()

        let transaction = try #require(try await database.getNextCrudTransaction())
        let entry = try #require(transaction.crud.first)
        #expect(entry.opData?.keys.contains("draft") == false)

        // Materialization resets the ephemeral value to its default.
        let fetched = try ModelContext(container).fetch(FetchDescriptor<EphemeralNote>())
        #expect(fetched.first?.title == "hola")
        #expect(fetched.first?.draft == "")

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func outOfRangeIntegersThrowInsteadOfTruncating() async throws {
        let database = try await TestDatabases.makeTypeMixDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([TypeMix.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "int-range", database: database)]
        )

        // A backend can sync any 64-bit integer into a column mapped to Int32.
        _ = try await database.execute(
            sql: """
            INSERT INTO ps_data__type_mix (id, data) VALUES (?, json_object(
                'text', 't', 'integer', 1, 'integer64', 1, 'integer32', 9999999999, 'flag', 0,
                'fraction', 1.0, 'fraction32', 1.0, 'stamp', 1700000000.0,
                'payload', 'AQI=', 'token', ?, 'mood', 'sunny', 'level', 1,
                'geo', '{"lat":0,"lon":0}'
            ))
            """,
            parameters: ["big", UUID().uuidString.lowercased()]
        )

        do {
            _ = try ModelContext(container).fetch(FetchDescriptor<TypeMix>())
            Issue.record("out-of-range Int32 should fail the fetch, not wrap around")
        } catch {
            #expect(String(describing: error).contains("integer32"))
        }

        try await database.close()
    }
}
