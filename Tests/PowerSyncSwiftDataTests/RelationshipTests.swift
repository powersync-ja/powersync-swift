import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Relationships: to-one is stored as a `{name}_id` column; to-many is resolved
/// through the inverse to-one; identifier remapping covers related models inserted in the
/// same save; many-to-many without an explicit join model is rejected with guidance.
@Suite("Relationships")
struct RelationshipTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    private static func makeContainer(
        name: String,
        database: any PowerSyncDatabaseProtocol
    ) throws -> ModelContainer {
        try ModelContainer(
            for: SwiftData.Schema([Playlist.self, Song.self]),
            configurations: [PowerSyncDataStoreConfiguration(name: name, database: database)]
        )
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func toOneRelationshipMapsToForeignKeyColumn() throws {
        let mapper = try SchemaMapper(
            schema: SwiftData.Schema([Playlist.self, Song.self]),
            tableNameForEntity: PowerSyncDataStoreConfiguration.defaultTableName(forEntityName:)
        )
        let song = try mapper.entity(named: "Song")
        let relationship = try #require(song.toOne.first)
        #expect(relationship.name == "playlist")
        #expect(relationship.columnName == "playlist_id")
        #expect(relationship.destinationEntityName == "Playlist")

        let playlist = try mapper.entity(named: "Playlist")
        let toMany = try #require(playlist.toMany.first)
        #expect(toMany.name == "songs")
        #expect(toMany.destinationEntityName == "Song")
        #expect(toMany.inverseColumnName == "playlist_id")
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func manyToManyWithoutJoinModelIsRejected() {
        #expect(throws: PowerSyncSwiftDataError.self) {
            _ = try SchemaMapper(
                schema: SwiftData.Schema([Conference.self, Speaker.self]),
                tableNameForEntity: PowerSyncDataStoreConfiguration.defaultTableName(forEntityName:)
            )
        }
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func toOneRoundTripsIncludingSameSaveInserts() async throws {
        let database = try await TestDatabases.makeMusicDatabase()
        let container = try Self.makeContainer(name: "relationships-toone", database: database)

        // Parent and child inserted in the SAME save: the child references the parent's
        // temporary identifier and the store's remapping must rewrite it.
        let context = ModelContext(container)
        let playlist = Playlist(id: "pl1", name: "Road trip")
        let song = Song(id: "s1", title: "Highway", playlist: playlist)
        context.insert(playlist)
        context.insert(song)
        try context.save()

        let transaction = try #require(try await database.getNextCrudTransaction())
        let byTable = Dictionary(grouping: transaction.crud, by: \.table)
        #expect(byTable["playlist"]?.count == 1)
        #expect(byTable["song"]?.count == 1)
        let songEntry = try #require(byTable["song"]?.first)
        #expect(songEntry.opData?["playlist_id"] == "pl1")
        try await transaction.complete()

        // Faulting from a fresh context: the song materializes its playlist through the
        // store (by identifier), and the playlist sees its songs through the inverse.
        let reader = ModelContext(container)
        let fetchedSong = try #require(try reader.fetch(FetchDescriptor<Song>()).first)
        #expect(fetchedSong.title == "Highway")
        #expect(fetchedSong.playlist?.id == "pl1")
        #expect(fetchedSong.playlist?.name == "Road trip")

        let fetchedPlaylist = try #require(try reader.fetch(FetchDescriptor<Playlist>()).first)
        #expect(fetchedPlaylist.songs.count == 1)
        #expect(fetchedPlaylist.songs.first?.id == "s1")

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func nullifyingToOnePersistsNull() async throws {
        let database = try await TestDatabases.makeMusicDatabase()
        let container = try Self.makeContainer(name: "relationships-nullify", database: database)

        let context = ModelContext(container)
        let playlist = Playlist(id: "pl1", name: "Road trip")
        let song = Song(id: "s1", title: "Highway", playlist: playlist)
        context.insert(playlist)
        context.insert(song)
        try context.save()
        try await #require(try await database.getNextCrudTransaction()).complete()

        song.playlist = nil
        try context.save()

        let patch = try #require(try await database.getNextCrudTransaction())
        let entry = try #require(patch.crud.first { $0.table == "song" })
        #expect(entry.op == .patch)
        if let stored = entry.opData?["playlist_id"] {
            #expect(stored == nil)
        }
        try await patch.complete()

        let reader = ModelContext(container)
        let fetched = try #require(try reader.fetch(FetchDescriptor<Song>()).first)
        #expect(fetched.playlist == nil)

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func cascadeDeleteRemovesChildren() async throws {
        let database = try await TestDatabases.makeMusicDatabase()
        let container = try Self.makeContainer(name: "relationships-cascade", database: database)

        let context = ModelContext(container)
        let playlist = Playlist(id: "pl1", name: "Road trip")
        context.insert(playlist)
        context.insert(Song(id: "s1", title: "Highway", playlist: playlist))
        context.insert(Song(id: "s2", title: "Byway", playlist: playlist))
        try context.save()
        try await #require(try await database.getNextCrudTransaction()).complete()

        context.delete(playlist)
        try context.save()

        let deletion = try #require(try await database.getNextCrudTransaction())
        let deletes = deletion.crud.filter { $0.op == .delete }
        #expect(Set(deletes.map(\.table)) == ["playlist", "song"])
        #expect(deletes.count == 3)

        let reader = ModelContext(container)
        #expect(try reader.fetch(FetchDescriptor<Song>()).isEmpty)
        #expect(try reader.fetch(FetchDescriptor<Playlist>()).isEmpty)

        try await database.close()
    }

    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func translatesIdentifierAndRelationshipPredicates() async throws {
        let database = try await TestDatabases.makeMusicDatabase()
        let container = try Self.makeContainer(name: "relationships-predicates", database: database)

        let context = ModelContext(container)
        let roadTrip = Playlist(id: "pl1", name: "Road trip")
        let chill = Playlist(id: "pl2", name: "Chill")
        context.insert(roadTrip)
        context.insert(chill)
        context.insert(Song(id: "s1", title: "Highway", playlist: roadTrip))
        context.insert(Song(id: "s2", title: "Lo-fi", playlist: chill))
        context.insert(Song(id: "s3", title: "Byway", playlist: roadTrip))
        try context.save()

        let mapper = try SchemaMapper(
            schema: SwiftData.Schema([Playlist.self, Song.self]),
            tableNameForEntity: PowerSyncDataStoreConfiguration.defaultTableName(forEntityName:)
        )
        let translator = PredicateTranslator(
            entity: try mapper.entity(named: "Song"),
            modelType: Song.self
        )

        // persistentModelID equality binds the PowerSync primary key. Note: the song's
        // OWN identifier compares against the id column; this test uses a song pid.
        let songPid = try #require(try context.fetch(
            FetchDescriptor<Song>(predicate: #Predicate { $0.id == "s1" })
        ).first).persistentModelID
        let byIdentifier = try translator.translateWhere(#Predicate<Song> { song in
            song.persistentModelID == songPid
        })
        #expect(byIdentifier.clause == "\"id\" = ?")
        #expect(byIdentifier.bindings[0] as? String == "s1")

        // Identifier membership (the shape SwiftData uses when faulting by identifiers).
        let pids: Set<PersistentIdentifier> = [songPid]
        let byMembership = try translator.translateWhere(#Predicate<Song> { song in
            pids.contains(song.persistentModelID)
        })
        #expect(byMembership.clause == "\"id\" IN (?)")
        #expect(byMembership.bindings[0] as? String == "s1")

        // Filtering by a related row's id through optional chaining translates to the
        // foreign-key column directly (see ChainedPredicateTests for the full matrix).
        let chained = try translator.translateWhere(#Predicate<Song> { song in
            song.playlist?.id == "pl1"
        })
        #expect(chained.clause == "\"playlist_id\" = ?")
        let reader = ModelContext(container)
        let songs = try reader.fetch(FetchDescriptor<Song>(predicate: #Predicate { song in
            song.playlist?.id == "pl1"
        }))
        #expect(Set(songs.map(\.id)) == ["s1", "s3"])

        try await database.close()
    }
}
