@testable import GRDB
@testable import PowerSync
@testable import PowerSyncGRDB

import XCTest

struct User: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String

    static var databaseTableName = "users"

    enum Columns {
        static let name = Column(CodingKeys.name)
    }
}

final class GRDBTests: XCTestCase {
    private var database: PowerSyncDatabaseProtocol!
    private var schema: Schema!
    private var pool: DatabasePool!

    override func setUp() async throws {
        try await super.setUp()
        schema = Schema(tables: [
            Table(name: "users", columns: [
                .text("name"),
            ])
        ])

        var config = Configuration()
        configurePowerSync(
            config: &config,
            schema: schema
        )

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

    func testBasicOperations() async throws {
        // Create users with the PowerSync SDK
        let initialUserName = "Bob"

        try await database.execute(
            sql: "INSERT INTO users(id, name) VALUES(uuid(), ?)",
            parameters: [initialUserName]
        )

        // Fetch those users
        let initialUserNames = try await database.getAll(
            "SELECT * FROM users"
        ) { cursor in
            try cursor.getString(name: "name")
        }

        XCTAssertTrue(initialUserNames.first == initialUserName)

        // Now define a GRDB struct for query purposes
        // Query the Users with GRDB, this should have the same result as with PowerSync
        let grdbUserNames = try await pool.read { database in
            try User.fetchAll(database)
        }

        XCTAssertTrue(grdbUserNames.first?.name == initialUserName)

        // Insert a user with GRDB
        try await pool.write { database in
            try User(
                id: UUID().uuidString,
                name: "another",
            ).insert(database)
        }

        let grdbUserNames2 = try await pool.read { database in
            try User.order(User.Columns.name.asc).fetchAll(database)
        }
        XCTAssert(grdbUserNames2.count == 2)
        XCTAssert(grdbUserNames2[1].name == "another")
    }

    func testPowerSyncUpdates() async throws {
        let expectation = XCTestExpectation(description: "Watch changes")

        // Create an actor to handle concurrent mutations
        actor ResultsStore {
            private var results: Set<String> = []

            func append(_ names: [String]) {
                results.formUnion(names)
            }

            func getResults() -> Set<String> {
                results
            }

            func count() -> Int {
                results.count
            }
        }

        let resultsStore = ResultsStore()

        let watchTask = Task {
            let stream = try database.watch(
                options: WatchOptions(
                    sql: "SELECT name FROM users ORDER BY id",
                    mapper: { cursor in
                        try cursor.getString(index: 0)
                    }
                ))
            for try await names in stream {
                await resultsStore.append(names)
                if await resultsStore.count() == 2 {
                    expectation.fulfill()
                }
            }
        }

        try await database.execute(
            sql: "INSERT INTO users(id, name) VALUES(uuid(), ?)",
            parameters: ["one"]
        )

        try await database.execute(
            sql: "INSERT INTO users(id, name) VALUES(uuid(), ?)",
            parameters: ["two"]
        )
        await fulfillment(of: [expectation], timeout: 5)
        watchTask.cancel()
    }

    func testPowerSyncUpdatesFromGRDB() async throws {
        let expectation = XCTestExpectation(description: "Watch changes")

        // Create an actor to handle concurrent mutations
        actor ResultsStore {
            private var results: Set<String> = []

            func append(_ names: [String]) {
                results.formUnion(names)
            }

            func getResults() -> Set<String> {
                results
            }

            func count() -> Int {
                results.count
            }
        }

        let resultsStore = ResultsStore()

        let watchTask = Task {
            let stream = try database.watch(
                options: WatchOptions(
                    sql: "SELECT name FROM users ORDER BY id",
                    mapper: { cursor in
                        try cursor.getString(index: 0)
                    }
                ))
            for try await names in stream {
                await resultsStore.append(names)
                if await resultsStore.count() == 2 {
                    expectation.fulfill()
                }
            }
        }

        try await pool.write { database in
            try User(
                id: UUID().uuidString,
                name: "one",
            ).insert(database)
        }

        try await pool.write { database in
            try User(
                id: UUID().uuidString,
                name: "two",
            ).insert(database)
        }

        await fulfillment(of: [expectation], timeout: 5)
        watchTask.cancel()
    }

    func testGRDBUpdatesFromPowerSync() async throws {
        let expectation = XCTestExpectation(description: "Watch changes")

        // Create an actor to handle concurrent mutations
        actor ResultsStore {
            private var results: Set<String> = []

            func append(_ names: [String]) {
                results.formUnion(names)
            }

            func getResults() -> Set<String> {
                results
            }

            func count() -> Int {
                results.count
            }
        }

        let resultsStore = ResultsStore()

        let watchTask = Task {
            let observation = ValueObservation.tracking {
                try User.order(User.Columns.name.asc).fetchAll($0)
            }

            for try await users in observation.values(in: pool) {
                print("users \(users)")
                await resultsStore.append(users.map { $0.name })
                if await resultsStore.count() == 2 {
                    expectation.fulfill()
                }
            }
        }

        try await database.execute(
            sql: "INSERT INTO users(id, name) VALUES(uuid(), ?)",
            parameters: ["one"]
        )

        try await database.execute(
            sql: "INSERT INTO users(id, name) VALUES(uuid(), ?)",
            parameters: ["two"]
        )

        await fulfillment(of: [expectation], timeout: 5)
        watchTask.cancel()
    }

    func testGRDBUpdatesFromGRDB() async throws {
        let expectation = XCTestExpectation(description: "Watch changes")

        // Create an actor to handle concurrent mutations
        actor ResultsStore {
            private var results: Set<String> = []

            func append(_ names: [String]) {
                results.formUnion(names)
            }

            func getResults() -> Set<String> {
                results
            }

            func count() -> Int {
                results.count
            }
        }

        let resultsStore = ResultsStore()

        let watchTask = Task {
            let observation = ValueObservation.tracking {
                try User.order(User.Columns.name.asc).fetchAll($0)
            }

            for try await users in observation.values(in: pool) {
                await resultsStore.append(users.map { $0.name })
                if await resultsStore.count() == 2 {
                    expectation.fulfill()
                }
            }
        }

        try await pool.write { database in
            try User(
                id: UUID().uuidString,
                name: "one",
            ).insert(database)
        }

        try await pool.write { database in
            try User(
                id: UUID().uuidString,
                name: "two",
            ).insert(database)
        }

        await fulfillment(of: [expectation], timeout: 5)
        watchTask.cancel()
    }
}
