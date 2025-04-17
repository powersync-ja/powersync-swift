import XCTest
@testable import PowerSync

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
}

final class SqlCursorTests: XCTestCase {
    private var database: KotlinPowerSyncDatabaseImpl!
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
        
        database = KotlinPowerSyncDatabaseImpl(
            schema: schema,
            dbFilename: ":memory:",
            logger:  DatabaseLogger(DefaultLogger())
        )
        try await database.disconnectAndClear()
    }
    
    override func tearDown() async throws {
        try await database.disconnectAndClear()
        database = nil
        try await super.tearDown()
    }
    
    func testValidValues() async throws {
        _ = try await database.execute(
            sql: "INSERT INTO users (id, count, is_active, weight) VALUES (?, ?, ?, ?)",
            parameters: ["1", 110, 0, 1.1111]
        )
        
        let user: User = try await database.get(
            sql: "SELECT id, count, is_active, weight FROM users WHERE id = ?",
            parameters: ["1"]
        ) { cursor in
            User(
                id: try cursor.getString(name: "id"),
                count: try cursor.getLong(name: "count"),
                isActive: try cursor.getBoolean(name: "is_active"),
                weight: try cursor.getDouble(name: "weight")
            )
        }
        
        XCTAssertEqual(user.id, "1")
        XCTAssertEqual(user.count, 110)
        XCTAssertEqual(user.isActive, false)
        XCTAssertEqual(user.weight, 1.1111)
    }
    
    func testOptionalValues() async throws {
        _ = try await database.execute(
            sql: "INSERT INTO users (id, count, is_active, weight, description) VALUES (?, ?, ?, ?, ?)",
            parameters: ["1", nil, nil, nil, nil, nil]
        )
        
        let user: UserOptional = try await database.get(
            sql: "SELECT id, count, is_active, weight, description FROM users WHERE id = ?",
            parameters: ["1"]
        ) { cursor in
            UserOptional(
                id: try cursor.getString(name: "id"),
                count: try cursor.getLongOptional(name: "count"),
                isActive: try cursor.getBooleanOptional(name: "is_active"),
                weight: try cursor.getDoubleOptional(name: "weight"),
                description: try cursor.getStringOptional(name: "description")
            )
        }
        
        XCTAssertEqual(user.id, "1")
        XCTAssertNil(user.count)
        XCTAssertNil(user.isActive)
        XCTAssertNil(user.weight)
        XCTAssertNil(user.description)
    }
}
