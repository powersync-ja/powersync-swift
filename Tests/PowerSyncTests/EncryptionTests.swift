@testable import PowerSync
import XCTest


final class EncryptionTests: XCTestCase {

    func testLinksSqlcipher() async throws {
        let database = KotlinPowerSyncDatabaseImpl(
            schema: Schema(),
            dbFilename: ":memory:",
            logger: DatabaseLogger(DefaultLogger())
        )
        
        let version = try await database.get("pragma cipher_version", mapper:  {cursor in
            try cursor.getString(index: 0)
        });
        
        XCTAssertEqual(version, "4.11.0 community")
        try await database.close()
    }

    func testEncryption() async throws {
        let database = KotlinPowerSyncDatabaseImpl(
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

        let another = KotlinPowerSyncDatabaseImpl(
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
                "pragma key = 'wrong password'"
            ],
        )
        
        var hadError = false
        do {
            try await database.execute("DELETE FROM users")
        } catch let error {
            hadError = true
        }
        
        XCTAssertTrue(hadError)
    }
}
