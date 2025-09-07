@testable import GRDB
@testable import PowerSync
@testable import PowerSyncGRDB

import XCTest

final class GRDBTests: XCTestCase {
    private var database: PowerSyncDatabaseProtocol!
    private var schema: Schema!

    override func setUp() async throws {
        try await super.setUp()
        schema = Schema(tables: [
            Table(name: "users", columns: [
                .text("count"),
                .integer("is_active"),
                .real("weight"),
                .text("description")
            ])
        ])

        var config = Configuration()
        configurePowerSync(&config)

        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbURL = documentsDir.appendingPathComponent("test.sqlite")
        let pool = try DatabasePool(
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
            "SELECT powersync_rs_version as r"
        ) { cursor in
            try cursor.getString(index: 0)
        }
        print(result)
    }
}
