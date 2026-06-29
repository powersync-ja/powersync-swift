import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// The PowerSync schema is derived from the SwiftData models, so applications
/// declare their `@Model`s once instead of duplicating tables and columns.
@Suite("Schema builder")
struct SchemaBuilderTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func derivesTablesColumnsAndForeignKeyIndexes() throws {
        let schema = try PowerSyncSchema(for: [Playlist.self, Song.self, TypeMix.self])

        let tables = Dictionary(uniqueKeysWithValues: schema.tables.map { ($0.name, $0) })
        #expect(Set(tables.keys) == ["playlist", "song", "type_mix"])

        let song = try #require(tables["song"])
        let songColumns = Dictionary(uniqueKeysWithValues: song.columns.map { ($0.name, $0.type) })
        #expect(songColumns["title"] == .text)
        #expect(songColumns["playlist_id"] == .text)
        // The implicit PowerSync id column must never be declared.
        #expect(songColumns["id"] == nil)
        // Foreign keys get an index for the inverse to-many resolution.
        #expect(song.indexes.contains { $0.name == "playlist_id" })

        let typeMix = try #require(tables["type_mix"])
        let columns = Dictionary(uniqueKeysWithValues: typeMix.columns.map { ($0.name, $0.type) })
        #expect(columns["text"] == .text)
        #expect(columns["integer"] == .integer)
        #expect(columns["flag"] == .integer)
        #expect(columns["fraction"] == .real)
        #expect(columns["stamp"] == .real)
        #expect(columns["payload"] == .text)
        #expect(columns["token"] == .text)
        #expect(columns["mood"] == .text)
        #expect(columns["level"] == .integer)
        #expect(columns["geo"] == .text)
        #expect(columns["subtitle"] == .text)
        #expect(columns["optionalStamp"] == .real)

        try schema.validate()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func builtSchemaRoundTripsThroughTheStore() async throws {
        let database = PowerSyncDatabase(
            schema: try PowerSyncSchema(for: [Playlist.self, Song.self]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()

        let container = try ModelContainer(
            for: SwiftData.Schema([Playlist.self, Song.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: "schema-builder-roundtrip", database: database)]
        )
        let context = ModelContext(container)
        let playlist = Playlist(id: "pl1", name: "Derivada")
        context.insert(playlist)
        context.insert(Song(id: "s1", title: "Uno", playlist: playlist))
        try context.save()

        let reader = ModelContext(container)
        let fetched = try #require(try reader.fetch(FetchDescriptor<Playlist>()).first)
        #expect(fetched.songs.count == 1)

        try await database.close()
    }
}
