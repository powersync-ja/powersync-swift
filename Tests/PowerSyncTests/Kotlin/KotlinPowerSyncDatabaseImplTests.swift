import XCTest
@testable import PowerSync

final class KotlinPowerSyncDatabaseImplTests: XCTestCase {
    private var database: KotlinPowerSyncDatabaseImpl!
    private var schema: Schema!

    override func setUp() async throws {
        try await super.setUp()
        schema = Schema(tables: [
            Table(name: "users", columns: [
                .text("name"),
                .text("email")
            ])
        ])

        database = KotlinPowerSyncDatabaseImpl(
            schema: schema,
            dbFilename: ":memory:"
        )
        try await database.disconnectAndClear()
    }

    override func tearDown() async throws {
        try await database.disconnectAndClear()
        database = nil
        try await super.tearDown()
    }

    func testInsertAndGet() async throws {
        _ = try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )

        let user: (String, String, String) = try await database.get(
            sql: "SELECT id, name, email FROM users WHERE id = ?",
            parameters: ["1"]
        ) { cursor in
            (
                try cursor.getString(name: "id"),
                try cursor.getString(name: "name"),
                try cursor.getString(name: "email")
            )
        }

        XCTAssertEqual(user.0, "1")
        XCTAssertEqual(user.1, "Test User")
        XCTAssertEqual(user.2, "test@example.com")
    }

    func testGetOptional() async throws {
        let nonExistent: String? = try await database.getOptional(
            sql: "SELECT name FROM users WHERE id = ?",
            parameters: ["999"]
        ) { cursor in
            cursor.getString(index: 0)!
        }

        XCTAssertNil(nonExistent)

        _ = try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )

        let existing: String? = try await database.getOptional(
            sql: "SELECT name FROM users WHERE id = ?",
            parameters: ["1"]
        ) { cursor in
            cursor.getString(index: 0)!
        }

        XCTAssertEqual(existing, "Test User")
    }

    func testGetAll() async throws {
        _ = try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?), (?, ?, ?)",
            parameters: ["1", "User 1", "user1@example.com", "2", "User 2", "user2@example.com"]
        )

        let users: [(String, String)] = try await database.getAll(
            sql: "SELECT id, name FROM users ORDER BY id",
            parameters: nil
        ) { cursor in
            (
                try cursor.getString(name: "id"),
                try cursor.getString(name: "name")
            )
        }

        XCTAssertEqual(users.count, 2)
        XCTAssertEqual(users[0].0, "1")
        XCTAssertEqual(users[0].1, "User 1")
        XCTAssertEqual(users[1].0, "2")
        XCTAssertEqual(users[1].1, "User 2")
    }

    func testWatchTableChanges() async throws {
        let expectation = XCTestExpectation(description: "Watch changes")

        // Create an actor to handle concurrent mutations
        actor ResultsStore {
            private var results: [[String]] = []

            func append(_ names: [String]) {
                results.append(names)
            }

            func getResults() -> [[String]] {
                results
            }

            func count() -> Int {
                results.count
            }
        }

        let resultsStore = ResultsStore()

        let stream = database.watch(
            sql: "SELECT name FROM users ORDER BY id",
            parameters: nil
        ) { cursor in
            cursor.getString(index: 0)!
        }

        let watchTask = Task {
            for await names in stream {
                await resultsStore.append(names)
                if await resultsStore.count() == 2 {
                    expectation.fulfill()
                }
            }
        }

        _ = try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "User 1", "user1@example.com"]
        )

        _ = try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["2", "User 2", "user2@example.com"]
        )

        await fulfillment(of: [expectation], timeout: 5)
        watchTask.cancel()

        let finalResults = await resultsStore.getResults()
        XCTAssertEqual(finalResults.count, 2)
        XCTAssertEqual(finalResults[1], ["User 1", "User 2"])
    }

    func testWriteTransaction() async throws {
        _ = try await database.writeTransaction { transaction in
            _ = transaction.execute(
                sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                parameters: ["1", "Test User", "test@example.com"]
            )

            _ = transaction.execute(
                sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                parameters: ["2", "Test User 2", "test2@example.com"]
            )
        }


        let result = try await database.get(
            sql: "SELECT COUNT(*) FROM users",
            parameters: []
        ) { cursor in
            cursor.getLong(index: 0)
        }

        XCTAssertEqual(result as! Int, 2)
    }

    func testWriteLongerTransaction() async throws {
        let loopCount = 100

        _ = try await database.writeTransaction { transaction in
            for i in 1...loopCount {
                _ = transaction.execute(
                    sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                    parameters: [String(i), "Test User \(i)", "test\(i)@example.com"]
                )

                _ = transaction.execute(
                    sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                    parameters: [String(i*10000), "Test User \(i)-2", "test\(i)-2@example.com"]
                )
            }
        }

        let result = try await database.get(
            sql: "SELECT COUNT(*) FROM users",
            parameters: []
        ) { cursor in
            cursor.getLong(index: 0)
        }

        XCTAssertEqual(result as! Int, 2 * loopCount)
    }

    func testReadTransaction() async throws {
        _ = try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )


        _ = try await database.readTransaction { transaction in
            let result = transaction.get(
                sql: "SELECT COUNT(*) FROM users",
                parameters: []
            ) { cursor in
                cursor.getLong(index: 0)
            }

            XCTAssertEqual(result as! Int, 1)
        }
    }
}
