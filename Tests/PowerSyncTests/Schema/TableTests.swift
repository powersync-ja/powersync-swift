import XCTest
@testable import PowerSync

final class TableTests: XCTestCase {
    
    private func makeValidColumns() -> [Column] {
        return [
            Column.text("name"),
            Column.integer("age"),
            Column.real("score")
        ]
    }
    
    private func makeValidIndex() -> Index {
        return Index(name: "test_index", columns: [
            IndexedColumn(column: "name")
        ])
    }
    
    func testBasicInitialization() {
        let name = "users"
        let columns = makeValidColumns()
        let indexes = [makeValidIndex()]
        
        let table = Table(
            name: name,
            columns: columns,
            indexes: indexes,
            localOnly: true,
            insertOnly: true,
            viewNameOverride: "user_view"
        )
        
        XCTAssertEqual(table.name, name)
        XCTAssertEqual(table.columns, columns)
        XCTAssertEqual(table.indexes.count, indexes.count)
        XCTAssertTrue(table.localOnly)
        XCTAssertTrue(table.insertOnly)
        XCTAssertEqual(table.viewNameOverride, "user_view")
    }
    
    func testViewName() {
        let table1 = Table(name: "users", columns: makeValidColumns())
        XCTAssertEqual(table1.viewName, "users")
        
        let table2 = Table(name: "users", columns: makeValidColumns(), viewNameOverride: "custom_view")
        XCTAssertEqual(table2.viewName, "custom_view")
    }
    
    func testInternalName() {
        let localTable = Table(name: "users", columns: makeValidColumns(), localOnly: true)
        XCTAssertEqual(localTable.internalName, "ps_data_local__users")
        
        let globalTable = Table(name: "users", columns: makeValidColumns(), localOnly: false)
        XCTAssertEqual(globalTable.internalName, "ps_data__users")
    }
    
    func testTooManyColumnsValidation() throws {
        var manyColumns: [Column] = []
        for i in 0..<64 {
            manyColumns.append(Column.text("column\(i)"))
        }
        
        let table = Table(name: "test", columns: manyColumns)
        
        XCTAssertThrowsError(try table.validate()) { error in
            guard case TableError.tooManyColumns(let tableName, let count) = error else {
                XCTFail("Expected tooManyColumns error")
                return
            }
            XCTAssertEqual(tableName, "test")
            XCTAssertEqual(count, 64)
        }
    }
    
    func testInvalidViewNameValidation() {
        let table = Table(
            name: "test",
            columns: makeValidColumns(),
            viewNameOverride: "invalid name"
        )
        
        XCTAssertThrowsError(try table.validate()) { error in
            guard case TableError.invalidViewName(let viewName) = error else {
                XCTFail("Expected invalidViewName error")
                return
            }
            XCTAssertEqual(viewName, "invalid name")
        }
    }
    
    func testCustomIdColumnValidation() {
        let columns = [Column.text("id")]
        let table = Table(name: "test", columns: columns)
        
        XCTAssertThrowsError(try table.validate()) { error in
            guard case TableError.customIdColumn(let tableName) = error else {
                XCTFail("Expected customIdColumn error")
                return
            }
            XCTAssertEqual(tableName, "test")
        }
    }
    
    func testDuplicateColumnValidation() {
        let columns = [
            Column.text("name"),
            Column.text("name")
        ]
        let table = Table(name: "test", columns: columns)
        
        XCTAssertThrowsError(try table.validate()) { error in
            guard case TableError.duplicateColumn(let tableName, let columnName) = error else {
                XCTFail("Expected duplicateColumn error")
                return
            }
            XCTAssertEqual(tableName, "test")
            XCTAssertEqual(columnName, "name")
        }
    }
    
    func testInvalidColumnNameValidation() {
        let columns = [Column.text("invalid name")]
        let table = Table(name: "test", columns: columns)
        
        XCTAssertThrowsError(try table.validate()) { error in
            guard case TableError.invalidColumnName(let tableName, let columnName) = error else {
                XCTFail("Expected invalidColumnName error")
                return
            }
            XCTAssertEqual(tableName, "test")
            XCTAssertEqual(columnName, "invalid name")
        }
    }
    
    // MARK: - Index Validation Tests
    
    func testDuplicateIndexValidation() {
        let index = Index(name: "test_index", columns: [IndexedColumn(column: "name")])
        let table = Table(
            name: "test",
            columns: [Column.text("name")],
            indexes: [index, index]
        )
        
        XCTAssertThrowsError(try table.validate()) { error in
            guard case TableError.duplicateIndex(let tableName, let indexName) = error else {
                XCTFail("Expected duplicateIndex error")
                return
            }
            XCTAssertEqual(tableName, "test")
            XCTAssertEqual(indexName, "test_index")
        }
    }
    
    func testInvalidIndexNameValidation() {
        let index = Index(name: "invalid index", columns: [IndexedColumn(column: "name")])
        let table = Table(
            name: "test",
            columns: [Column.text("name")],
            indexes: [index]
        )
        
        XCTAssertThrowsError(try table.validate()) { error in
            guard case TableError.invalidIndexName(let tableName, let indexName) = error else {
                XCTFail("Expected invalidIndexName error")
                return
            }
            XCTAssertEqual(tableName, "test")
            XCTAssertEqual(indexName, "invalid index")
        }
    }
    
    func testColumnNotFoundInIndexValidation() {
        let index = Index(name: "test_index", columns: [IndexedColumn(column: "nonexistent")])
        let table = Table(
            name: "test",
            columns: [Column.text("name")],
            indexes: [index]
        )
        
        XCTAssertThrowsError(try table.validate()) { error in
            guard case TableError.columnNotFound(let tableName, let columnName, let indexName) = error else {
                XCTFail("Expected columnNotFound error")
                return
            }
            XCTAssertEqual(tableName, "test")
            XCTAssertEqual(columnName, "nonexistent")
            XCTAssertEqual(indexName, "test_index")
        }
    }
    
    func testValidTableValidation() throws {
        let table = Table(
            name: "users",
            columns: makeValidColumns(),
            indexes: [makeValidIndex()],
            localOnly: false,
            insertOnly: false
        )
        
        XCTAssertNoThrow(try table.validate())
    }
}
