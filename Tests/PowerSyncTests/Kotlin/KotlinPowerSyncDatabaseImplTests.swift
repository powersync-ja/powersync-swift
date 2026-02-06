import struct Foundation.UUID
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
            SqliteException(1): SQL logic error, no such table: usersfail for SQL: INSERT INTO usersfail (id, name, email) VALUES (?, ?, ?)
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
            _ = try await database.get(
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
            SqliteException(1): SQL logic error, no such table: usersfail for SQL: SELECT id, name, email FROM usersfail WHERE id = ?
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
            _ = try await database.getOptional(
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
            SqliteException(1): SQL logic error, no such table: usersfail for SQL: SELECT id, name, email FROM usersfail WHERE id = ?
            """)
        }
    }

    func testMapperError() async throws {
        try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )
        do {
            _ = try await database.getOptional(
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

    func testCustomDataTypeConvertible() async throws {
        let uuid = UUID()
        try await database.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: [uuid, "Test User", "test@example.com"]
        )

        _ = try await database.getOptional(
            sql: "SELECT id, name, email FROM users WHERE id = ?",
            parameters: [uuid]
        ) { cursor throws in
            try (
                cursor.getString(name: "id"),
                cursor.getString(name: "name"),
                cursor.getString(name: "email")
            )
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
            _ = try await database.getAll(
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
            SqliteException(1): SQL logic error, no such table: usersfail for SQL: SELECT id, name, email FROM usersfail WHERE id = ?
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
            SqliteException(1): SQL logic error, no such table: usersfail for SQL: EXPLAIN SELECT name FROM usersfail ORDER BY id
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
            SqliteException(1): SQL logic error, no such table: usersfail for SQL: INSERT INTO usersfail (id, name, email) VALUES (?, ?, ?)
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
            SqliteException(1): SQL logic error, no such table: usersfail for SQL: INSERT INTO usersfail (id, name, email) VALUES (?, ?, ?)
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
            SqliteException(1): SQL logic error, no such table: usersfail for SQL: SELECT COUNT(*) FROM usersfail
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

        let db2 = openKotlinDBDefault(
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

        let db2 = openKotlinDBDefault(
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

    func testCloseWithDeleteDatabase() async throws {
        let fileManager = FileManager.default
        let testDbFilename = "test_delete_\(UUID().uuidString).db"

        // Get the database directory using the helper function
        let databaseDirectory = try appleDefaultDatabaseDirectory()

        // Create a database with a real file
        let testDatabase = PowerSyncDatabase(
            schema: schema,
            dbFilename: testDbFilename,
            logger: DatabaseLogger(DefaultLogger())
        )

        // Perform some operations to ensure the database file is created
        try await testDatabase.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )

        // Verify the database file exists
        let dbFile = databaseDirectory.appendingPathComponent(testDbFilename)
        XCTAssertTrue(fileManager.fileExists(atPath: dbFile.path), "Database file should exist")

        // Close with deleteDatabase: true
        try await testDatabase.close(deleteDatabase: true)

        // Verify the database file and related files are deleted
        XCTAssertFalse(fileManager.fileExists(atPath: dbFile.path), "Database file should be deleted")

        let walFile = databaseDirectory.appendingPathComponent("\(testDbFilename)-wal")
        let shmFile = databaseDirectory.appendingPathComponent("\(testDbFilename)-shm")
        let journalFile = databaseDirectory.appendingPathComponent("\(testDbFilename)-journal")

        XCTAssertFalse(fileManager.fileExists(atPath: walFile.path), "WAL file should be deleted")
        XCTAssertFalse(fileManager.fileExists(atPath: shmFile.path), "SHM file should be deleted")
        XCTAssertFalse(fileManager.fileExists(atPath: journalFile.path), "Journal file should be deleted")
    }

    func testCloseWithoutDeleteDatabase() async throws {
        let fileManager = FileManager.default
        let testDbFilename = "test_no_delete_\(UUID().uuidString).db"

        // Get the database directory using the helper function
        let databaseDirectory = try appleDefaultDatabaseDirectory()

        // Create a database with a real file
        let testDatabase = PowerSyncDatabase(
            schema: schema,
            dbFilename: testDbFilename,
            logger: DatabaseLogger(DefaultLogger())
        )

        // Perform some operations to ensure the database file is created
        try await testDatabase.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )

        // Verify the database file exists
        let dbFile = databaseDirectory.appendingPathComponent(testDbFilename)
        XCTAssertTrue(fileManager.fileExists(atPath: dbFile.path), "Database file should exist")

        // Close with deleteDatabase: false (default)
        try await testDatabase.close()

        // Verify the database file still exists
        XCTAssertTrue(fileManager.fileExists(atPath: dbFile.path), "Database file should still exist after close without delete")

        // Clean up: delete all SQLite files using the helper function
        try deleteSQLiteFiles(dbFilename: testDbFilename, in: databaseDirectory)
    }

    func testCustomDbDirectory() async throws {
        let fileManager = FileManager.default
        let testDbFilename = "test_custom_dir_\(UUID().uuidString).db"
        let customDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("powersync_test_\(UUID().uuidString)")

        // Create the custom directory
        try fileManager.createDirectory(at: customDirectory, withIntermediateDirectories: true)

        let testDatabase = PowerSyncDatabase(
            schema: schema,
            dbFilename: testDbFilename,
            dbDirectory: customDirectory.path,
            logger: DatabaseLogger(DefaultLogger())
        )

        // Perform an operation to ensure the database file is created
        try await testDatabase.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )

        // Verify the database file exists in the custom directory
        let dbFile = customDirectory.appendingPathComponent(testDbFilename)
        XCTAssertTrue(fileManager.fileExists(atPath: dbFile.path), "Database file should exist in custom directory")

        // Verify the file does NOT exist in the default directory
        let defaultDirectory = try appleDefaultDatabaseDirectory()
        let defaultDbFile = defaultDirectory.appendingPathComponent(testDbFilename)
        XCTAssertFalse(fileManager.fileExists(atPath: defaultDbFile.path), "Database file should not exist in default directory")

        // Close and clean up
        try await testDatabase.close(deleteDatabase: true)

        // Verify the database file is deleted from the custom directory
        XCTAssertFalse(fileManager.fileExists(atPath: dbFile.path), "Database file should be deleted from custom directory")

        // Clean up the temporary directory
        try? fileManager.removeItem(at: customDirectory)
    }

    func testCustomDbDirectoryCloseWithDeleteDatabase() async throws {
        let fileManager = FileManager.default
        let testDbFilename = "test_custom_delete_\(UUID().uuidString).db"
        let customDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("powersync_test_\(UUID().uuidString)")

        try fileManager.createDirectory(at: customDirectory, withIntermediateDirectories: true)

        let testDatabase = PowerSyncDatabase(
            schema: schema,
            dbFilename: testDbFilename,
            dbDirectory: customDirectory.path,
            logger: DatabaseLogger(DefaultLogger())
        )

        try await testDatabase.execute(
            sql: "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            parameters: ["1", "Test User", "test@example.com"]
        )

        let dbFile = customDirectory.appendingPathComponent(testDbFilename)
        let walFile = customDirectory.appendingPathComponent("\(testDbFilename)-wal")
        let shmFile = customDirectory.appendingPathComponent("\(testDbFilename)-shm")

        XCTAssertTrue(fileManager.fileExists(atPath: dbFile.path), "Database file should exist")

        try await testDatabase.close(deleteDatabase: true)

        // Verify all SQLite files are deleted from the custom directory
        XCTAssertFalse(fileManager.fileExists(atPath: dbFile.path), "Database file should be deleted")
        XCTAssertFalse(fileManager.fileExists(atPath: walFile.path), "WAL file should be deleted")
        XCTAssertFalse(fileManager.fileExists(atPath: shmFile.path), "SHM file should be deleted")

        try? fileManager.removeItem(at: customDirectory)
    }

    func testSubscriptionsUpdateStateWhileOffline() async throws {
        var streams = database.currentStatus.asFlow().makeAsyncIterator()
        let initialStatus = await streams.next(); // Ignore initial
        XCTAssertEqual(initialStatus?.syncStreams?.count, 0)
        
        // Subscribing while offline should add the stream to the subscriptions reported in the status.
        let subscription = try await database.syncStream(name: "foo", params: ["foo": JsonValue.string("bar")]).subscribe()
        let updatedStatus = await streams.next();
        
        XCTAssertEqual(updatedStatus?.syncStreams?.count, 1)
        let status = updatedStatus?.forStream(stream: subscription)
        XCTAssertNotNil(status)
        
        XCTAssertNil(status?.progress)
    }
    
    func testSubscriptionParameters() async throws {
        var streams = database.currentStatus.asFlow().makeAsyncIterator()
        let initialStatus = await streams.next(); // Ignore initial
        XCTAssertEqual(initialStatus?.syncStreams?.count, 0)
        
        let _ = try await database.syncStream(name: "foo", params: [
            "text": JsonValue.string("text"),
            "int1": JsonValue.int(1),
            "int0": JsonValue.int(0),
            "double": JsonValue.double(1.23),
            "bool": JsonValue.bool(true),
        ]).subscribe()
        let updatedStatus = await streams.next();
        
        XCTAssertEqual(updatedStatus?.syncStreams?.count, 1)
        let stream = updatedStatus!.syncStreams![0]
        let params = stream.subscription.parameters!
        XCTAssertEqual(params["text"], JsonValue.string("text"))
        XCTAssertEqual(params["int1"], JsonValue.int(1))
        XCTAssertEqual(params["int0"], JsonValue.int(0))
        XCTAssertEqual(params["double"], JsonValue.double(1.23))
        XCTAssertEqual(params["bool"], JsonValue.bool(true))
    }
}

extension UUID: PowerSyncDataTypeConvertible {
    public var psDataType: PowerSyncDataType? {
        .string(uuidString)
    }
}
