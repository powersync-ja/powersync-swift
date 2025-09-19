@testable import PowerSync
import XCTest

struct User {
    let id: String
    let count: Int
    let isActive: Bool
    let weight: Double
}

struct UserOptional {
    let id: String
    let count: Int?
    let isActive: Bool?
    let weight: Double?
    let description: String?

    init(
        id: String,
        count: Int? = nil,
        isActive: Bool? = nil,
        weight: Double? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.count = count
        self.isActive = isActive
        self.weight = weight
        self.description = description
    }
}

func createTestUser(
    db: PowerSyncDatabaseProtocol,
    userData: UserOptional = UserOptional(
        id: "1",
        count: 110,
        isActive: false,
        weight: 1.1111
    )
) async throws {
    try await db.execute(
        sql: "INSERT INTO users (id, count, is_active, weight) VALUES (?, ?, ?, ?)",
        parameters: [
            userData.id,
            userData.count,
            userData.isActive,
            userData.weight
        ]
    )
}

final class SqlCursorTests: XCTestCase {
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

        database = openKotlinDBWithFactory(
            schema: schema,
            dbFilename: ":memory:",
            logger: DatabaseLogger(DefaultLogger())
        )
        try await database.disconnectAndClear()
    }

    override func tearDown() async throws {
        try await database.disconnectAndClear()
        database = nil
        try await super.tearDown()
    }

    func testValidValues() async throws {
        try await createTestUser(
            db: database
        )

        let user: User = try await database.get(
            sql: "SELECT id, count, is_active, weight FROM users WHERE id = ?",
            parameters: ["1"]
        ) { cursor in
            try User(
                id: cursor.getString(name: "id"),
                count: cursor.getInt(name: "count"),
                isActive: cursor.getBoolean(name: "is_active"),
                weight: cursor.getDouble(name: "weight")
            )
        }

        XCTAssertEqual(user.id, "1")
        XCTAssertEqual(user.count, 110)
        XCTAssertEqual(user.isActive, false)
        XCTAssertEqual(user.weight, 1.1111)
    }

    /// Uses the indexed based cursor methods to obtain a required column value
    func testValidValuesWithIndex() async throws {
        try await createTestUser(
            db: database
        )

        let user = try await database.get(
            sql: "SELECT id, count, is_active, weight FROM users WHERE id = ?",
            parameters: ["1"]
        ) { cursor in
            try UserOptional(
                id: cursor.getString(index: 0),
                count: cursor.getInt(index: 1),
                isActive: cursor.getBoolean(index: 2),
                weight: cursor.getDoubleOptional(index: 3)
            )
        }

        XCTAssertEqual(user.id, "1")
        XCTAssertEqual(user.count, 110)
        XCTAssertEqual(user.isActive, false)
        XCTAssertEqual(user.weight, 1.1111)
    }

    /// Uses index based cursor methods which are optional and don't throw
    func testIndexNoThrow() async throws {
        try await createTestUser(
            db: database
        )

        let user = try await database.get(
            sql: "SELECT id, count, is_active, weight FROM users WHERE id = ?",
            parameters: ["1"]
        ) { cursor in
            UserOptional(
                id: cursor.getStringOptional(index: 0) ?? "1",
                count: cursor.getIntOptional(index: 1),
                isActive: cursor.getBooleanOptional(index: 2),
                weight: cursor.getDoubleOptional(index: 3)
            )
        }

        XCTAssertEqual(user.id, "1")
        XCTAssertEqual(user.count, 110)
        XCTAssertEqual(user.isActive, false)
        XCTAssertEqual(user.weight, 1.1111)
    }

    func testOptionalValues() async throws {
        try await createTestUser(
            db: database,
            userData: UserOptional(
                id: "1",
                count: nil,
                isActive: nil,
                weight: nil,
                description: nil
            )
        )

        let user: UserOptional = try await database.get(
            sql: "SELECT id, count, is_active, weight, description FROM users WHERE id = ?",
            parameters: ["1"]
        ) { cursor in
            try UserOptional(
                id: cursor.getString(name: "id"),
                count: cursor.getIntOptional(name: "count"),
                isActive: cursor.getBooleanOptional(name: "is_active"),
                weight: cursor.getDoubleOptional(name: "weight"),
                description: cursor.getStringOptional(name: "description")
            )
        }

        XCTAssertEqual(user.id, "1")
        XCTAssertNil(user.count)
        XCTAssertNil(user.isActive)
        XCTAssertNil(user.weight)
        XCTAssertNil(user.description)
    }

    /// Tests that a `mapper` which does not throw is accepted by the protocol
    func testNoThrow() async throws {
        try await createTestUser(
            db: database
        )

        let user = try await database.get(
            sql: "SELECT id, count, is_active, weight FROM users WHERE id = ?",
            parameters: ["1"]
        ) { cursor in
            try UserOptional(
                id: cursor.getString(index: 0),
                count: cursor.getInt(index: 1),
                isActive: cursor.getBoolean(index: 2),
                weight: cursor.getDouble(index: 3),
                description: nil
            )
        }

        XCTAssertEqual(user.id, "1")
        XCTAssertEqual(user.count, 110)
        XCTAssertEqual(user.isActive, false)
        XCTAssertEqual(user.weight, 1.1111)
    }

    func testThrowsForMissingColumn() async throws {
        try await createTestUser(
            db: database
        )

        do {
            _ = try await database.get(
                sql: "SELECT id FROM users",
                parameters: []
            ) { cursor in
                try cursor.getString(name: "missing")
            }
            XCTFail("An Error should have been thrown due to a missing column")
        } catch let SqlCursorError.columnNotFound(columnName) {
            // The throw Error should contain the missing column name
            XCTAssertEqual(columnName, "missing")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testThrowsForNullValuedRequiredColumn() async throws {
        /// Create a test user with nil stored in columns
        try await createTestUser(
            db: database,
            userData: UserOptional(
                id: "1",
                count: nil,
                isActive: nil,
                weight: nil,
                description: nil
            )
        )

        do {
            _ = try await database.get(
                sql: "SELECT description FROM users",
                parameters: []
            ) { cursor in
                // Request a required column. A nil value here will throw
                try cursor.getString(name: "description")
            }
            XCTFail("An Error should have been thrown due to a missing column")
        } catch let SqlCursorError.nullValueFound(columnName) {
            // The throw Error should contain the missing column name
            XCTAssertEqual(columnName, "description")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// Index based cursor methods should throw if null is returned for required values
    func testThrowsForNullValuedRequiredColumnIndex() async throws {
        /// Create a test user with nil stored in columns
        try await createTestUser(
            db: database,
            userData: UserOptional(
                id: "1",
                count: nil,
                isActive: nil,
                weight: nil,
                description: nil
            )
        )

        do {
            _ = try await database.get(
                sql: "SELECT description FROM users",
                parameters: []
            ) { cursor in
                // Request a required column. A nil value here will throw
                try cursor.getString(index: 0)
            }
            XCTFail("An Error should have been thrown due to a missing column")
        } catch let SqlCursorError.nullValueFound(columnName) {
            // The throw Error should contain the missing column name
            XCTAssertEqual(columnName, "0")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
