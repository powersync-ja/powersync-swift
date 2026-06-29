import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Per-property column-name overrides: Swift models keep idiomatic camelCase property
/// names while mapping to conventional snake_case Postgres columns, without renaming
/// either side.
@Suite("Column overrides")
struct ColumnOverrideTests {
    static let snakeCase: @Sendable (String, String) -> String? = { _, property in
        var result = ""
        for character in property {
            if character.isUppercase {
                result.append("_")
                result.append(contentsOf: character.lowercased())
            } else {
                result.append(character)
            }
        }
        return result == property ? nil : result
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func mapsPropertiesToOverriddenColumnsEndToEnd() async throws {
        // Stamp model: `createdAt` property, `created_at` column.
        let database = PowerSyncDatabase(
            schema: try PowerSyncSchema(
                for: [Stamp.self],
                columnNameForProperty: Self.snakeCase
            ),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()

        // The derived schema uses the overridden column names.
        let derived = try PowerSyncSchema(for: [Stamp.self], columnNameForProperty: Self.snakeCase)
        let table = try #require(derived.tables.first { $0.name == "stamp" })
        #expect(table.columns.contains { $0.name == "created_at" })
        #expect(!table.columns.contains { $0.name == "createdAt" })

        let container = try ModelContainer(
            for: SwiftData.Schema([Stamp.self]),
            configurations: [PowerSyncDataStoreConfiguration(
                name: "column-overrides",
                database: database,
                columnNameForProperty: Self.snakeCase
            )]
        )

        let context = ModelContext(container)
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(Stamp(id: "s1", createdAt: moment, displayName: "uno"))
        try context.save()

        // The upload queue carries the COLUMN names (what the backend expects).
        let batch = try #require(try await database.getCrudBatch())
        let opData = try #require(batch.crud.first?.opData)
        #expect(opData.keys.contains("created_at"))
        #expect(opData.keys.contains("display_name"))
        #expect(!opData.keys.contains("createdAt"))

        // Round trip and predicate translation work against the overridden columns.
        let reader = ModelContext(container)
        let cutoff = moment.addingTimeInterval(-1)
        let fetched = try reader.fetch(FetchDescriptor<Stamp>(
            predicate: #Predicate { $0.createdAt > cutoff },
            sortBy: [SortDescriptor(\.displayName)]
        ))
        #expect(fetched.first?.displayName == "uno")
        #expect(fetched.first?.createdAt == moment)

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func overriddenColumnsAreValidatedAgainstTheDatabase() async throws {
        // A database whose table has the DEFAULT column names: container creation with the
        // override must fail descriptively (the overridden column is missing).
        let database = PowerSyncDatabase(
            schema: try PowerSyncSchema(for: [Stamp.self]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()

        do {
            _ = try ModelContainer(
                for: SwiftData.Schema([Stamp.self]),
                configurations: [PowerSyncDataStoreConfiguration(
                    name: "column-overrides-mismatch",
                    database: database,
                    columnNameForProperty: Self.snakeCase
                )]
            )
            Issue.record("container creation should fail when overridden columns are missing")
        } catch {
            #expect(String(describing: error).contains("created_at"))
        }
        try await database.close()
    }
}
