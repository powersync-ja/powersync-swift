import XCTest
@testable import PowerSyncSwift

final class SchemaTests: XCTestCase {
    private func makeValidTable(name: String) -> Table {
        return Table(
            name: name,
            columns: [
                Column.text("name"),
                Column.integer("age")
            ]
        )
    }
    
    private func makeInvalidTable() -> Table {
        // Table with invalid column name
        return Table(
            name: "test",
            columns: [
                Column.text("invalid name")
            ]
        )
    }
    
    func testArrayInitialization() {
        let tables = [
            makeValidTable(name: "users"),
            makeValidTable(name: "posts")
        ]
        
        let schema = Schema(tables: tables)
        
        XCTAssertEqual(schema.tables.count, 2)
        XCTAssertEqual(schema.tables[0].name, "users")
        XCTAssertEqual(schema.tables[1].name, "posts")
    }
    
    func testVariadicInitialization() {
        let schema = Schema(
            makeValidTable(name: "users"),
            makeValidTable(name: "posts")
        )
        
        XCTAssertEqual(schema.tables.count, 2)
        XCTAssertEqual(schema.tables[0].name, "users")
        XCTAssertEqual(schema.tables[1].name, "posts")
    }
    
    func testEmptySchemaInitialization() {
        let schema = Schema(tables: [])
        XCTAssertTrue(schema.tables.isEmpty)
        XCTAssertNoThrow(try schema.validate())
    }
    
    func testDuplicateTableValidation() {
        let schema = Schema(
            makeValidTable(name: "users"),
            makeValidTable(name: "users")
        )
        
        XCTAssertThrowsError(try schema.validate()) { error in
            guard case SchemaError.duplicateTableName(let tableName) = error else {
                XCTFail("Expected duplicateTableName error")
                return
            }
            XCTAssertEqual(tableName, "users")
        }
    }
    
    func testCascadingTableValidation() {
        let schema = Schema(
            makeValidTable(name: "users"),
            makeInvalidTable()
        )
        
        XCTAssertThrowsError(try schema.validate()) { error in
            // The error should be from the Table validation
            guard case TableError.invalidColumnName = error else {
                XCTFail("Expected invalidColumnName error from Table validation")
                return
            }
        }
    }
    
    func testValidSchemaValidation() {
        let schema = Schema(
            makeValidTable(name: "users"),
            makeValidTable(name: "posts"),
            makeValidTable(name: "comments")
        )
        
        XCTAssertNoThrow(try schema.validate())
    }
    
    func testSingleTableSchema() {
        let schema = Schema(makeValidTable(name: "users"))
        XCTAssertEqual(schema.tables.count, 1)
        XCTAssertNoThrow(try schema.validate())
    }
    
    func testTableAccess() {
        let users = makeValidTable(name: "users")
        let posts = makeValidTable(name: "posts")
        
        let schema = Schema(users, posts)
        
        XCTAssertEqual(schema.tables[0].name, users.name)
        XCTAssertEqual(schema.tables[1].name, posts.name)
    }
}
