import Foundation
import PowerSync

/// In-memory PowerSync databases for the test models.
enum TestDatabases {
    /// Table for ``Note``.
    static func makeNoteDatabase() async throws -> any PowerSyncDatabaseProtocol {
        let database = PowerSyncDatabase(
            schema: PowerSync.Schema(tables: [
                Table(
                    name: "note",
                    columns: [
                        .text("title"),
                        .integer("done"),
                        .integer("count"),
                    ]
                ),
            ]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()
        return database
    }

    /// Table for ``TypeMix`` (every supported attribute type).
    static func makeTypeMixDatabase() async throws -> any PowerSyncDatabaseProtocol {
        let database = PowerSyncDatabase(
            schema: PowerSync.Schema(tables: [
                Table(
                    name: "type_mix",
                    columns: [
                        .text("text"),
                        .integer("integer"),
                        .integer("integer64"),
                        .integer("integer32"),
                        .integer("flag"),
                        .real("fraction"),
                        .real("fraction32"),
                        .real("stamp"),
                        .text("payload"),
                        .text("token"),
                        .text("mood"),
                        .integer("level"),
                        .text("geo"),
                        .text("subtitle"),
                        .integer("optionalNumber"),
                        .real("optionalStamp"),
                        .text("optionalPayload"),
                    ]
                ),
            ]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()
        return database
    }

    /// Tables for ``Playlist``/``Song`` (to-one and to-many relationships).
    static func makeMusicDatabase() async throws -> any PowerSyncDatabaseProtocol {
        let database = PowerSyncDatabase(
            schema: PowerSync.Schema(tables: [
                Table(name: "playlist", columns: [.text("name")]),
                Table(
                    name: "song",
                    columns: [
                        .text("title"),
                        .text("playlist_id"),
                    ]
                ),
            ]),
            dbFilename: ":memory:",
            logger: DefaultLogger(minSeverity: .warning)
        )
        try await database.disconnectAndClear()
        return database
    }
}
