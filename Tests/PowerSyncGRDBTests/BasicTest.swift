@testable import GRDB
@testable import PowerSync
@testable import PowerSyncGRDB

import XCTest

struct User: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String

    static var databaseTableName = "users"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
    }
}

struct Pet: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    var ownerId: String

    static var databaseTableName = "pets"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerId = "owner_id"
    }

    enum Columns {
        static let ownerId = Column(CodingKeys.ownerId)
    }

    static let user = belongsTo(
        User.self,
        key: "user",
        using: ForeignKey([Columns.ownerId], to: [User.Columns.id])
    )
}

final class GRDBTests: XCTestCase {
    private var database: PowerSyncDatabaseProtocol!
    private var schema: Schema!
    private var pool: DatabasePool!

    override func setUp() async throws {
        try await super.setUp()
        schema = Schema(tables: [
            Table(name: "users", columns: [
                .text("name")
            ]),
            Table(name: "pets", columns: [
                .text("name"),
                .text("owner_id")
            ])
        ])

        var config = Configuration()

        config.configurePowerSync(
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

    func testJoins() async throws {
        // Create users with the PowerSync SDK
        try await pool.write { database in
            let userId = UUID().uuidString
            try User(
                id: userId,
                name: "Bob"
            ).insert(database)

            try Pet(
                id: UUID().uuidString,
                name: "Fido",
                ownerId: userId
            ).insert(database)
        }

        struct PetWithUser: Decodable, FetchableRecord {
            struct PartialUser: Decodable {
                var name: String
            }

            var pet: Pet // The base record
            var user: PartialUser // The partial associated record
        }

        let petsWithUsers = try await pool.read { db in
            try Pet
                .including(required: Pet.user)
                .asRequest(of: PetWithUser.self)
                .fetchAll(db)
        }

        XCTAssert(petsWithUsers.count == 1)
        XCTAssert(petsWithUsers[0].pet.name == "Fido")
        XCTAssert(petsWithUsers[0].user.name == "Bob")
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
