@testable import PowerSync
import Testing

@Suite()
struct EncryptionTests {
    @Test("SQLite3MultipleCiphers pragmas are available") @MainActor
    func linksSqlite3Mc() async throws {
        let database = PowerSyncDatabase(
            schema: Schema(),
            dbFilename: "linkSqlite3Mc",
            logger: DatabaseLogger(DefaultLogger())
        )
        
        let cipher = try await database.get("pragma cipher", mapper:  {cursor in
            try cursor.getString(index: 0)
        });
        
        #expect(cipher == "chacha20")
        try await database.close(deleteDatabase: true)
    }

    @Test("can encrypt databases") @MainActor
    func encryption() async throws {
        let database = PowerSyncDatabase(
            schema: Schema(tables: [
                Table(
                    name: "users",
                    columns: [
                        .text("name")
                    ]
                ),
            ]),
            dbFilename: "encrypted.db",
            logger: DatabaseLogger(DefaultLogger()),
            initialStatements: [
                "pragma key = 'foobar'"
            ],
        )
        
        try await database.execute("INSERT INTO users (id, name) VALUES (uuid(), 'test')")
        try await database.close()

        let another = PowerSyncDatabase(
            schema: Schema(tables: [
                Table(
                    name: "users",
                    columns: [
                        .text("name")
                    ]
                ),
            ]),
            dbFilename: "encrypted.db",
            logger: DatabaseLogger(DefaultLogger()),
            initialStatements: [
                "pragma key = 'wrong password'",
            ],
        )
        
        await #expect(throws: (any Error).self) {
            try await another.execute("DELETE FROM users")
        }
        try await another.close(deleteDatabase: true)
    }
}
