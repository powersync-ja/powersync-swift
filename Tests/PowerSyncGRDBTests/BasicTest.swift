@testable import GRDB
@testable import PowerSync
@testable import PowerSyncGRDB

import XCTest

final class GRDBTests: XCTestCase {
    private var database: PowerSyncDatabaseProtocol!
    private var schema: Schema!
    private var pool: DatabasePool!

    override func setUp() async throws {
        try await super.setUp()
        schema = Schema(tables: [
            Table(name: "users", columns: [
                .text("name"),
                .text("count")
            ])
        ])

        var config = Configuration()
        configurePowerSync(&config)
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbURL = documentsDir.appendingPathComponent("test.sqlite")
        pool = try DatabasePool(
            path: dbURL.path,
            configuration: config
        )

        database = OpenedPowerSyncDatabase(
            schema: schema,
            pool: GRDBConnectionPool(
                pool: pool
            ),
            identifier: "test"
        )

        try await database.disconnectAndClear()
    }

    override func tearDown() async throws {
        try await database.disconnectAndClear()
        database = nil
        try await super.tearDown()
    }

    func testValidValues() async throws {
        let result = try await database.get(
            "SELECT powersync_rs_version() as r"
        ) { cursor in
            try cursor.getString(index: 0)
        }
        print(result)

        try await database.execute(
            "INSERT INTO users(id, name, count) VALUES(uuid(), 'steven', 1)"
        )

        let initialUsers = try await database.getAll(
            "SELECT * FROM users"
        ) { cursor in
            try cursor.getString(name: "name")
        }
        print("initial users \(initialUsers)")

        // Now use a GRDB query
        struct Users: Codable, Identifiable, FetchableRecord, PersistableRecord {
            var id: String
            var name: String
            var count: Int

            enum Columns {
                static let name = Column(CodingKeys.name)
                static let count = Column(CodingKeys.count)
            }
        }

        let grdbUsers = try await pool.write { db in
            try Users.fetchAll(db)
        }

        print(grdbUsers)
    }
}
