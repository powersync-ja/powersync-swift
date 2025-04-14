@testable import PowerSync
import XCTest

final class KotlinPowerSyncDatabaseImplTests: XCTestCase {
    private var database: KotlinPowerSyncDatabaseImpl!
    private var schema: Schema!

    override func setUp() async throws {
        try await super.setUp()
        schema = Schema(tables: [
            Table(name: "users", columns: [
                .text("name"),
                .text("email"),
            ]),
        ])

        database = KotlinPowerSyncDatabaseImpl(
            schema: schema,
            dbFilename: ":memory:",
            logger: DatabaseLogger(DefaultLogger())
        )
        try await database.disconnectAndClear()
    }

    override func tearDown() async throws {
        try await database.disconnectAndClear()
        // Tests currently fail if this is called.
        // The watched query tests try and read from the DB while it's closing. 
        // This causes a PowerSyncException to be thrown in the Kotlin flow.
        // Custom exceptions in flows are not supported by SKIEE. This causes a crash.
        // FIXME: Reapply once watched query errors are handled better.
        // try await database.close()
        database = nil
        try await super.tearDown()
    }

    func testExecuteError() async throws {
        do {
            _ = try await database.execute(
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
        _ = try await database.execute(
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
        _ = try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )
        do {
            let _ = try await database.getOptional(
                sql: "SELECT id, name, email FROM users WHERE id = ?",
                parameters: ["1"]
            ) { _ throws in
                throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "cursor error"])
            }
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertEqual(error.localizedDescription, "cursor error")
        }
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
                    cursor.getString(index: 0)!
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
                cursor.getString(index: 0)!
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
            cursor.getLong(index: 0)
        }

        XCTAssertEqual(result as! Int, 2)
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
            cursor.getLong(index: 0)
        }

        XCTAssertEqual(result as! Int, 2 * loopCount)
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
        ) { cursor in try cursor.getLong(index: 0)
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
                cursor.getLong(index: 0)
            }

            XCTAssertEqual(result as! Int, 1)
        }
    }

    func testReadTransactionError() async throws {
        do {
            _ = try await database.readTransaction { transaction in
                let result = try transaction.get(
                    sql: "SELECT COUNT(*) FROM usersfail",
                    parameters: []
                ) { cursor in
                    cursor.getLong(index: 0)
                }
            }
        } catch {
            XCTAssertEqual(error.localizedDescription, """
            error while compiling: SELECT COUNT(*) FROM usersfail
            no such table: usersfail
            """)
        }
    }

    func testFTS() async throws {
        let supported = try await database.get(
            "SELECT sqlite_compileoption_used('ENABLE_FTS5');"
        ) { cursor in
            cursor.getLong(index: 0)
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
        ) { cursor in cursor.getLong(index: 0) }

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
        
        let warningIndex = testWriter.logs.firstIndex(
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
        
        let warningIndex = testWriter.logs.firstIndex(
            where: { value in
                value.contains("warning: Multiple PowerSync instances for the same database have been detected")
            }
        )
        
        // The warning should not be present due to the min severity
        XCTAssert(warningIndex == nil)
    }
}
