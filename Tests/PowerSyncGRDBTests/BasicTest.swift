@testable import GRDB
@testable import PowerSync
@testable import PowerSyncGRDB

import XCTest

struct User: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String

    static let databaseTableName = "users"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
    }
}

struct Pet: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    var ownerId: String

    static let databaseTableName = "pets"

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

        // Use a unique identifier per test instance to avoid conflicts during parallel test execution
        let dbIdentifier = "test-\(UUID().uuidString).sqlite"

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

        try config.configurePowerSync(
            schema: schema
        )

        guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw XCTestError(
                .failureWhileWaiting,
                userInfo: [NSLocalizedDescriptionKey: "Could not access documents directory"]
            )
        }

        // Ensure the documents directory exists
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true, attributes: nil)

        let dbURL = documentsDir.appendingPathComponent(dbIdentifier)
        pool = try DatabasePool(
            path: dbURL.path,
            configuration: config
        )

        database = openPowerSyncWithGRDB(
            pool: pool,
            schema: schema,
            identifier: dbIdentifier
        )

        try await database.disconnectAndClear()
    }

    override func tearDown() async throws {
        try? await database?.disconnectAndClear()
        database = nil
        try? pool?.close()
        pool = nil
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

        let watchTask = Task { [database] in
            guard let database = database else {
                XCTFail("Database is nil")
                return
            }

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

        let watchTask = Task { [database] in
            guard let database = database else {
                XCTFail("Database is nil")
                return
            }
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

        let watchTask = Task { [pool] in
            guard let pool = pool else {
                XCTFail("Database pool is nil")
                return
            }
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

    func testShouldThrowErrorsFromPowerSync() async throws {
        do {
            try await database.execute(
                sql: "INSERT INTO non_existent_table(id, name) VALUES(uuid(), ?)",
                parameters: ["one"]
            )
            XCTFail("Should throw error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("non_existent_table")) // Expected
        }
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

        let watchTask = Task { [pool] in
            guard let pool = pool else {
                XCTFail("Database pool is nil")
                return
            }

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
