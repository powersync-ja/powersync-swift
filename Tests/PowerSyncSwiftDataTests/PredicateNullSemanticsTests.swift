import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// SQL three-valued logic must not leak into predicate results: `!=` and `NOT` over
/// optional columns include NULL rows exactly like Swift's optional semantics, UUID
/// constants match rows synced by lowercase-rendering backends, and `fetchCount` honors
/// `fetchOffset`. Every behavior is pinned against the in-memory fallback semantics.
@Suite("Predicate NULL semantics and count")
struct PredicateNullSemanticsTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    private static func typeMixTranslator() throws -> PredicateTranslator {
        let mapper = try SchemaMapper(
            schema: SwiftData.Schema([TypeMix.self]),
            tableNameForEntity: PowerSyncDataStoreConfiguration.defaultTableName(forEntityName:)
        )
        return PredicateTranslator(entity: try mapper.entity(named: "TypeMix"), modelType: TypeMix.self)
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func notEqualOnOptionalColumnIncludesNullRows() throws {
        let translator = try Self.typeMixTranslator()

        let notEqual = try translator.translateWhere(#Predicate<TypeMix> { $0.subtitle != "x" })
        #expect(notEqual.clause == "(\"subtitle\" IS NULL OR \"subtitle\" != ?)")

        // Non-optional columns keep the plain form.
        let nonOptional = try translator.translateWhere(#Predicate<TypeMix> { $0.text != "x" })
        #expect(nonOptional.clause == "\"text\" != ?")
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func negationOverNullableClauseCoalesces() throws {
        let translator = try Self.typeMixTranslator()

        let negated = try translator.translateWhere(#Predicate<TypeMix> { !($0.subtitle == "x") })
        #expect(negated.clause == "NOT (COALESCE((\"subtitle\" = ?), 0))")

        // Negation over a never-NULL clause keeps the plain form.
        let plain = try translator.translateWhere(#Predicate<TypeMix> { !($0.text == "x") })
        #expect(plain.clause == "NOT (\"text\" = ?)")
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func sqlResultsMatchInMemorySemanticsForNullRows() async throws {
        let database = try await TestDatabases.makeTypeMixDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([TypeMix.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "null-semantics", database: database)]
        )

        // Three rows: subtitle = "x", subtitle = "y", subtitle = NULL (key absent).
        for id in ["a", "b", "c"] {
            _ = try await database.execute(
                sql: """
                INSERT INTO ps_data__type_mix (id, data) VALUES (?, json_object(
                    'text', 't', 'integer', 1, 'integer64', 1, 'integer32', 1, 'flag', 0,
                    'fraction', 1.0, 'fraction32', 1.0, 'stamp', 1700000000.0,
                    'payload', 'AQI=', 'token', ?, 'mood', 'sunny', 'level', 1,
                    'geo', '{"lat":0,"lon":0}'
                ))
                """,
                parameters: [id, UUID().uuidString.lowercased()]
            )
        }
        _ = try await database.execute(
            sql: "UPDATE ps_data__type_mix SET data = json_set(data, '$.subtitle', ?) WHERE id = 'a'",
            parameters: ["x"]
        )
        _ = try await database.execute(
            sql: "UPDATE ps_data__type_mix SET data = json_set(data, '$.subtitle', ?) WHERE id = 'b'",
            parameters: ["y"]
        )

        let reader = ModelContext(container)

        // Swift semantics: subtitle != "x" is true for "y" AND for nil.
        let notEqual = try reader.fetch(FetchDescriptor<TypeMix>(
            predicate: #Predicate { $0.subtitle != "x" }
        ))
        #expect(Set(notEqual.map(\.id)) == ["b", "c"])

        // Swift semantics: !(subtitle == "x") is identical.
        let negated = try reader.fetch(FetchDescriptor<TypeMix>(
            predicate: #Predicate { !($0.subtitle == "x") }
        ))
        #expect(Set(negated.map(\.id)) == ["b", "c"])

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func uuidPredicatesMatchLowercaseBackendRows() async throws {
        let database = try await TestDatabases.makeTypeMixDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([TypeMix.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "uuid-lowercase", database: database)]
        )

        // Backends (Postgres) render uuid in lowercase; simulate a synced row.
        let token = UUID()
        _ = try await database.execute(
            sql: """
            INSERT INTO ps_data__type_mix (id, data) VALUES (?, json_object(
                'text', 't', 'integer', 1, 'integer64', 1, 'integer32', 1, 'flag', 0,
                'fraction', 1.0, 'fraction32', 1.0, 'stamp', 1700000000.0,
                'payload', 'AQI=', 'token', ?, 'mood', 'sunny', 'level', 1,
                'geo', '{"lat":0,"lon":0}'
            ))
            """,
            parameters: ["u1", token.uuidString.lowercased()]
        )

        let reader = ModelContext(container)
        let matched = try reader.fetch(FetchDescriptor<TypeMix>(
            predicate: #Predicate { $0.token == token }
        ))
        #expect(matched.count == 1)
        #expect(matched.first?.token == token)

        // And rows written by the store itself are also stored lowercase.
        let stored = try await database.get(
            sql: "SELECT token FROM type_mix WHERE id = ?",
            parameters: ["u1"]
        ) { try $0.getString(index: 0) }
        #expect(stored == stored.lowercased())

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func fetchCountHonorsOffsetAndLimit() async throws {
        let database = try await TestDatabases.makeNoteDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([Note.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "count-offset", database: database)]
        )
        let context = ModelContext(container)
        for index in 0 ..< 10 {
            context.insert(Note(id: "n\(index)", title: "t", done: false, count: index))
        }
        try context.save()

        let reader = ModelContext(container)
        var descriptor = FetchDescriptor<Note>()
        descriptor.fetchOffset = 8
        #expect(try reader.fetchCount(descriptor) == 2)

        descriptor.fetchLimit = 5
        #expect(try reader.fetchCount(descriptor) == 2)

        descriptor.fetchOffset = 2
        #expect(try reader.fetchCount(descriptor) == 5)

        descriptor.fetchOffset = 20
        #expect(try reader.fetchCount(descriptor) == 0)

        try await database.close()
    }
}
