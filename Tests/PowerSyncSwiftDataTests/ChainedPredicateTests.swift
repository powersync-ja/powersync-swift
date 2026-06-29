import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Optional-chained to-one predicates translate to SQL instead of falling back to
/// in-memory filtering: `$0.playlist?.id == x` compares the foreign-key column directly,
/// and `$0.playlist?.name == x` uses an `IN (SELECT id ...)` subquery — both with Swift's
/// optional-chain semantics (a nil relationship makes `==` false and `!=` true).
@Suite("Chained relationship predicates")
struct ChainedPredicateTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    private static func songTranslator() throws -> PredicateTranslator {
        let mapper = try SchemaMapper(
            schema: SwiftData.Schema([Playlist.self, Song.self]),
            tableNameForEntity: PowerSyncDataStoreConfiguration.defaultTableName(forEntityName:)
        )
        try SnapshotEntityRegistry.register(mapper)
        return PredicateTranslator(entity: try mapper.entity(named: "Song"), modelType: Song.self)
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func chainedIdComparesTheForeignKeyDirectly() throws {
        let translator = try Self.songTranslator()
        let listId = "p1"
        let translated = try translator.translateWhere(#Predicate<Song> { $0.playlist?.id == listId })
        #expect(translated.clause == "\"playlist_id\" = ?")
        #expect(translated.bindings.first as? String == "p1")

        // Swift: nil-chain != x is TRUE, so the negation must be NULL-safe.
        let negated = try translator.translateWhere(#Predicate<Song> { $0.playlist?.id != listId })
        #expect(negated.clause == "(\"playlist_id\" IS NULL OR \"playlist_id\" != ?)")
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func chainedAttributeUsesASubquery() throws {
        let translator = try Self.songTranslator()
        let translated = try translator.translateWhere(#Predicate<Song> { $0.playlist?.name == "Road" })
        #expect(translated.clause == "\"playlist_id\" IN (SELECT \"id\" FROM \"playlist\" WHERE \"name\" = ?)")

        let negated = try translator.translateWhere(#Predicate<Song> { $0.playlist?.name != "Road" })
        #expect(negated.clause
            == "(\"playlist_id\" IS NULL OR \"playlist_id\" NOT IN (SELECT \"id\" FROM \"playlist\" WHERE \"name\" = ?))")
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func chainedPredicatesMatchSwiftSemanticsEndToEnd() async throws {
        let database = try await TestDatabases.makeMusicDatabase()
        let container = try ModelContainer(
            for: SwiftData.Schema([Playlist.self, Song.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "chained", database: database)]
        )

        let context = ModelContext(container)
        let road = Playlist(id: "p1", name: "Road")
        let focus = Playlist(id: "p2", name: "Focus")
        context.insert(road)
        context.insert(focus)
        context.insert(Song(id: "s1", title: "en road", playlist: road))
        context.insert(Song(id: "s2", title: "en focus", playlist: focus))
        context.insert(Song(id: "s3", title: "huérfana", playlist: nil))
        try context.save()

        let reader = ModelContext(container)

        let inRoad = try reader.fetch(FetchDescriptor<Song>(
            predicate: #Predicate { $0.playlist?.name == "Road" }
        ))
        #expect(Set(inRoad.map(\.id)) == ["s1"])

        // Swift semantics: != is true for the other playlist AND for the nil chain.
        let notRoad = try reader.fetch(FetchDescriptor<Song>(
            predicate: #Predicate { $0.playlist?.name != "Road" }
        ))
        #expect(Set(notRoad.map(\.id)) == ["s2", "s3"])

        let byId = try reader.fetch(FetchDescriptor<Song>(
            predicate: #Predicate { $0.playlist?.id == "p2" }
        ))
        #expect(Set(byId.map(\.id)) == ["s2"])

        try await database.close()
    }
}
