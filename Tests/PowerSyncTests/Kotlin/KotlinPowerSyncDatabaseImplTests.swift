@testable import PowerSync
import XCTest

final class KotlinPowerSyncDatabaseImplTests: XCTestCase {
    private var database: (any PowerSyncDatabaseProtocol)!
    private var schema: Schema!

    override func setUp() async throws {
        try await super.setUp()
        schema = Schema(tables: [
            Table(
                name: "users",
                columns: [
                    .text("name"),
                    .text("email"),
                    .text("photo_id")
                ]
            )
        ])

        database = PowerSyncDatabase(
            schema: schema,
            dbFilename: ":memory:",
            logger: DatabaseLogger(DefaultLogger())
        )
        try await database.disconnectAndClear()
    }

    override func tearDown() async throws {
        try await database.disconnectAndClear()
        try await database.close()
        database = nil
        try await super.tearDown()
    }

    func testExecuteError() async throws {
        do {
            try await database.execute(
                sql: "INSERT INTO usersfail (id, name, email) VALUES (?, ?, ?)",
                parameters: ["1", "Test User", "test@example.com"]
            )
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertEqual(error.localizedDescription, """
            error while compiling: INSERT INTO usersfail (id, name, email) VALUES (?, ?, ?)
            no such table: usersfail
            """)
        }
    }

    func testInsertAndGet() async throws {
        try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )

        let user: (String, String, String) = try await database.get(
            sql: "SELECT id, name, email FROM users WHERE id = ?",
            parameters: ["1"]
        ) { cursor in
            try (
                cursor.getString(name: "id"),
                cursor.getString(name: "name"),
                cursor.getString(name: "email")
            )
        }

        XCTAssertEqual(user.0, "1")
        XCTAssertEqual(user.1, "Test User")
        XCTAssertEqual(user.2, "test@example.com")
    }

    func testGetError() async throws {
        do {
            let _ = try await database.get(
                sql: "SELECT id, name, email FROM usersfail WHERE id = ?",
                parameters: ["1"]
            ) { cursor in
                try (
                    cursor.getString(name: "id"),
                    cursor.getString(name: "name"),
                    cursor.getString(name: "email")
                )
            }
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertEqual(error.localizedDescription, """
            error while compiling: SELECT id, name, email FROM usersfail WHERE id = ?
            no such table: usersfail
            """)
        }
    }

    func testGetOptional() async throws {
        let nonExistent: String? = try await database.getOptional(
            sql: "SELECT name FROM users WHERE id = ?",
            parameters: ["999"]
        ) { cursor in
            try cursor.getString(name: "name")
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
            try cursor.getString(index: 0)
        }

        XCTAssertEqual(existing, "Test User")
    }

    func testGetOptionalError() async throws {
        do {
            let _ = try await database.getOptional(
                sql: "SELECT id, name, email FROM usersfail WHERE id = ?",
                parameters: ["1"]
            ) { cursor in
                try (
                    cursor.getString(name: "id"),
                    cursor.getString(name: "name"),
                    cursor.getString(name: "email")
                )
            }
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertEqual(error.localizedDescription, """
            error while compiling: SELECT id, name, email FROM usersfail WHERE id = ?
            no such table: usersfail
            """)
        }
    }

    func testMapperError() async throws {
        try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )
        do {
            let _ = try await database.getOptional(
                sql: "SELECT id, name, email FROM users WHERE id = ?",
                parameters: ["1"]
            ) { _ throws in
                throw NSError(
                    domain: "TestError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "cursor error"]
                )
            }
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertEqual(error.localizedDescription, "cursor error")
        }
    }

    func testGetAll() async throws {
        try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?), (?, ?, ?)",
            parameters: ["1", "User 1", "user1@example.com", "2", "User 2", "user2@example.com"]
        )

        let users: [(String, String)] = try await database.getAll(
            sql: "SELECT id, name FROM users ORDER BY id",
            parameters: nil
        ) { cursor in
            try (
                cursor.getString(name: "id"),
                cursor.getString(name: "name")
            )
        }

        XCTAssertEqual(users.count, 2)
        XCTAssertEqual(users[0].0, "1")
        XCTAssertEqual(users[0].1, "User 1")
        XCTAssertEqual(users[1].0, "2")
        XCTAssertEqual(users[1].1, "User 2")
    }

    func testGetAllError() async throws {
        do {
            let _ = try await database.getAll(
                sql: "SELECT id, name, email FROM usersfail WHERE id = ?",
                parameters: ["1"]
            ) { cursor in
                try (
                    cursor.getString(name: "id"),
                    cursor.getString(name: "name"),
                    cursor.getString(name: "email")
                )
            }
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertEqual(error.localizedDescription, """
            error while compiling: SELECT id, name, email FROM usersfail WHERE id = ?
            no such table: usersfail
            """)
        }
    }

    func testWatchTableChanges() async throws {
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

        let stream = try database.watch(
            options: WatchOptions(
                sql: "SELECT name FROM users ORDER BY id",
                mapper: { cursor in
                    try cursor.getString(index: 0)
                }
            ))

        let watchTask = Task {
            for try await names in stream {
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
        // The count of invocations here can vary a lot depending on the order of execution
        // In some cases the creation of the users can fire before the initial watched query
        // has emitted a result.
        // However the watched query should always emit the latest result set.
        XCTAssertLessThanOrEqual(finalResults.count, 3)
        XCTAssertEqual(finalResults, ["User 1", "User 2"])
    }

    func testWatchError() async throws {
        do {
            let stream = try database.watch(
                sql: "SELECT name FROM usersfail ORDER BY id",
                parameters: nil
            ) { cursor in
                try cursor.getString(index: 0)
            }

            // Actually consume the stream to trigger the error
            for try await _ in stream {
                XCTFail("Should not receive any values")
            }

            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertEqual(error.localizedDescription, """
            error while compiling: EXPLAIN SELECT name FROM usersfail ORDER BY id
            no such table: usersfail
            """)
        }
    }

    func testWatchMapperError() async throws {
        do {
            _ = try await database.execute(
                sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                parameters: ["1", "User 1", "user1@example.com"]
            )

            let stream = try database.watch(
                sql: "SELECT name FROM users ORDER BY id",
                parameters: nil
            ) { _ throws in throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "cursor error"]) }

            // Actually consume the stream to trigger the error
            for try await _ in stream {
                XCTFail("Should not receive any values")
            }

            XCTFail("Expected an error to be thrown")
        } catch {
            print(error.localizedDescription)
            XCTAssertEqual(error.localizedDescription, "cursor error")
        }
    }

    func testWriteTransaction() async throws {
        _ = try await database.writeTransaction { transaction in
            _ = try transaction.execute(
                sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                parameters: ["1", "Test User", "test@example.com"]
            )

            _ = try transaction.execute(
                sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                parameters: ["2", "Test User 2", "test2@example.com"]
            )
        }

        let result = try await database.get(
            sql: "SELECT COUNT(*) FROM users",
            parameters: []
        ) { cursor in
            try cursor.getInt(index: 0)
        }

        XCTAssertEqual(result, 2)
    }

    func testWriteLongerTransaction() async throws {
        let loopCount = 100

        _ = try await database.writeTransaction { transaction in
            for i in 1 ... loopCount {
                _ = try transaction.execute(
                    sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                    parameters: [String(i), "Test User \(i)", "test\(i)@example.com"]
                )

                _ = try transaction.execute(
                    sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                    parameters: [String(i * 10000), "Test User \(i)-2", "test\(i)-2@example.com"]
                )
            }
        }

        let result = try await database.get(
            sql: "SELECT COUNT(*) FROM users",
            parameters: []
        ) { cursor in
            try cursor.getInt(index: 0)
        }

        XCTAssertEqual(result, 2 * loopCount)
    }

    func testWriteTransactionError() async throws {
        do {
            _ = try await database.writeTransaction { transaction in
                _ = try transaction.execute(
                    sql: "INSERT INTO usersfail (id, name, email) VALUES (?, ?, ?)",
                    parameters: ["2", "Test User 2", "test2@example.com"]
                )
            }
        } catch {
            XCTAssertEqual(error.localizedDescription, """
            error while compiling: INSERT INTO usersfail (id, name, email) VALUES (?, ?, ?)
            no such table: usersfail
            """)
        }
    }

    func testWriteTransactionErrorPerformsRollBack() async throws {
        do {
            _ = try await database.writeTransaction { transaction in
                _ = try transaction.execute(
                    sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                    parameters: ["1", "Test User", "test@example.com"]
                )

                _ = try transaction.execute(
                    sql: "INSERT INTO usersfail (id, name, email) VALUES (?, ?, ?)",
                    parameters: ["2", "Test User 2", "test2@example.com"]
                )
            }
        } catch {
            XCTAssertEqual(error.localizedDescription, """
            error while compiling: INSERT INTO usersfail (id, name, email) VALUES (?, ?, ?)
            no such table: usersfail
            """)
        }

        let result = try await database.getOptional(
            sql: "SELECT COUNT(*) FROM users",
            parameters: []
        ) { cursor in try cursor.getInt(index: 0)
        }

        XCTAssertEqual(result, 0)
    }

    func testReadTransaction() async throws {
        _ = try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )

        _ = try await database.readTransaction { transaction in
            let result = try transaction.get(
                sql: "SELECT COUNT(*) FROM users",
                parameters: []
            ) { cursor in
                try cursor.getInt(index: 0)
            }

            XCTAssertEqual(result, 1)
        }
    }

    func testReadTransactionError() async throws {
        do {
            _ = try await database.readTransaction { transaction in
                _ = try transaction.get(
                    sql: "SELECT COUNT(*) FROM usersfail",
                    parameters: []
                ) { cursor in
                    try cursor.getInt(index: 0)
                }
            }
        } catch {
            XCTAssertEqual(error.localizedDescription, """
            error while compiling: SELECT COUNT(*) FROM usersfail
            no such table: usersfail
            """)
        }
    }

    /// Transactions should return the value returned from the callback
    func testTransactionReturnValue() async throws {
        // Should pass through nil
        let txNil = try await database.writeTransaction { _ in
            nil as Any?
        }
        XCTAssertNil(txNil)

        let txString = try await database.writeTransaction { _ in
            "Hello"
        }
        XCTAssertEqual(txString, "Hello")
    }

    /// Transactions should return the value returned from the callback
    func testTransactionGenerics() async throws {
        // Should pass through nil
        try await database.writeTransaction { tx in
            let result = try tx.get(
                sql: "SELECT FALSE as col",
                parameters: []
            ) { cursor in
                try cursor.getBoolean(name: "col")
            }

            // result should be typed as Bool
            XCTAssertFalse(result)
        }
    }

    func testFTS() async throws {
        let supported = try await database.get(
            "SELECT sqlite_compileoption_used('ENABLE_FTS5');"
        ) { cursor in
            try cursor.getInt(index: 0)
        }

        XCTAssertEqual(supported, 1)
    }

    func testUpdatingSchema() async throws {
        _ = try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )

        let newSchema = Schema(tables: [
            Table(
                name: "users",
                columns: [
                    .text("name"),
                    .text("email"),
                ],
                viewNameOverride: "people"
            ),
        ])

        try await database.updateSchema(schema: newSchema)

        let peopleCount = try await database.get(
            sql: "SELECT COUNT(*) FROM people",
            parameters: []
        ) { cursor in try cursor.getInt(index: 0) }

        XCTAssertEqual(peopleCount, 1)
    }

    func testCustomLogger() async throws {
        let testWriter = TestLogWriterAdapter()
        let logger = DefaultLogger(minSeverity: LogSeverity.debug, writers: [testWriter])

        let db2 = KotlinPowerSyncDatabaseImpl(
            schema: schema,
            dbFilename: ":memory:",
            logger: DatabaseLogger(logger)
        )

        try await db2.close()

        let warningIndex = testWriter.getLogs().firstIndex(
            where: { value in
                value.contains("warning: Multiple PowerSync instances for the same database have been detected")
            }
        )

        XCTAssert(warningIndex! >= 0)
    }

    func testMinimumSeverity() async throws {
        let testWriter = TestLogWriterAdapter()
        let logger = DefaultLogger(minSeverity: LogSeverity.error, writers: [testWriter])

        let db2 = KotlinPowerSyncDatabaseImpl(
            schema: schema,
            dbFilename: ":memory:",
            logger: DatabaseLogger(logger)
        )

        try await db2.close()

        let warningIndex = testWriter.getLogs().firstIndex(
            where: { value in
                value.contains("warning: Multiple PowerSync instances for the same database have been detected")
            }
        )

        // The warning should not be present due to the min severity
        XCTAssert(warningIndex == nil)
    }

    func testJoin() async throws {
        struct JoinOutput: Equatable {
            var name: String
            var description: String
            var comment: String
        }

        try await database.updateSchema(schema:
            Schema(tables: [
                Table(name: "users", columns: [
                    .text("name"),
                    .text("email"),
                    .text("photo_id")
                ]),
                Table(name: "tasks", columns: [
                    .text("user_id"),
                    .text("description"),
                    .text("tags")
                ]),
                Table(name: "comments", columns: [
                    .text("task_id"),
                    .text("comment"),
                ])
            ])
        )

        try await database.writeTransaction { transaction in
            let userId = UUID().uuidString
            try transaction.execute(
                sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                parameters: [userId, "Test User", "test@example.com"]
            )

            let task1Id = UUID().uuidString
            let task2Id = UUID().uuidString

            try transaction.execute(
                sql: "INSERT INTO tasks (id, user_id, description) VALUES (?, ?, ?)",
                parameters: [task1Id, userId, "task 1"]
            )

            try transaction.execute(
                sql: "INSERT INTO tasks (id, user_id, description) VALUES (?, ?, ?)",
                parameters: [task2Id, userId, "task 2"]
            )

            try transaction.execute(
                sql: "INSERT INTO comments (id, task_id, comment) VALUES (uuid(), ?, ?)",
                parameters: [task1Id, "comment 1"]
            )

            try transaction.execute(
                sql: "INSERT INTO comments (id, task_id, comment) VALUES (uuid(), ?, ?)",
                parameters: [task2Id, "comment 2"]
            )
        }

        let result = try await database.getAll(
            sql: """
                    SELECT
                        users.name as name,
                        tasks.description as description,
                        comments.comment as comment
                    FROM users
                    LEFT JOIN tasks ON users.id = tasks.user_id
                    LEFT JOIN comments ON tasks.id = comments.task_id;
            """,
            parameters: []
        ) { cursor in
            try JoinOutput(
                name: cursor.getString(name: "name"),
                description: cursor.getString(name: "description"),
                comment: cursor.getStringOptional(name: "comment") ?? ""
            )
        }

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], JoinOutput(name: "Test User", description: "task 1", comment: "comment 1"))
        XCTAssertEqual(result[1], JoinOutput(name: "Test User", description: "task 2", comment: "comment 2"))
    }
}
