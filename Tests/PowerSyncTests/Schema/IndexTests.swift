import XCTest
@testable import PowerSync

final class IndexTests: XCTestCase {
    
    private func makeIndexedColumn(_ name: String) -> IndexedColumnProtocol {
        return IndexedColumn.ascending(name)
    }
    
    func testBasicInitialization() {
        let name = "test_index"
        let columns: [IndexedColumnProtocol] = [
            makeIndexedColumn("column1"),
            makeIndexedColumn("column2")
        ]
        
        let index = Index(name: name, columns: columns)
        
        XCTAssertEqual(index.name, name)
        XCTAssertEqual(index.columns.count, 2)
        XCTAssertEqual((index.columns[0] as? IndexedColumn)?.column, "column1")
        XCTAssertEqual((index.columns[1] as? IndexedColumn)?.column, "column2")
    }
    
    func testVariadicInitialization() {
        let name = "test_index"
        let column1 = makeIndexedColumn("column1")
        let column2 = makeIndexedColumn("column2")
        
        let index = Index(name: name, column1, column2)
        
        XCTAssertEqual(index.name, name)
        XCTAssertEqual(index.columns.count, 2)
        XCTAssertEqual((index.columns[0]).column, "column1")
        XCTAssertEqual((index.columns[1]).column, "column2")
    }
    
    func testAscendingFactoryWithMultipleColumns() {
        let name = "test_index"
        let columnNames = ["column1", "column2", "column3"]
        
        let index = Index.ascending(name: name, columns: columnNames)
        
        XCTAssertEqual(index.name, name)
        XCTAssertEqual(index.columns.count, 3)
        
        // Verify each column is correctly created
        for (i, columnName) in columnNames.enumerated() {
            let indexedColumn = index.columns[i]
            XCTAssertEqual(indexedColumn.column, columnName)
            XCTAssertTrue(indexedColumn.ascending)
        }
    }
    
    func testAscendingFactoryWithSingleColumn() {
        let name = "test_index"
        let columnName = "column1"
        
        let index = Index.ascending(name: name, column: columnName)
        
        XCTAssertEqual(index.name, name)
        XCTAssertEqual(index.columns.count, 1)
        
        let indexedColumn = index.columns[0]
        XCTAssertEqual(indexedColumn.column, columnName)
        XCTAssertTrue(indexedColumn.ascending)
    }
    
    func testMixedColumnTypes() {
        let name = "mixed_index"
        let columns: [IndexedColumnProtocol] = [
            IndexedColumn.ascending("column1"),
            IndexedColumn.descending("column2"),
            IndexedColumn.ascending("column3")
        ]
        
        let index = Index(name: name, columns: columns)
        
        XCTAssertEqual(index.name, name)
        XCTAssertEqual(index.columns.count, 3)
    
        let col1 = index.columns[0]
        let col2 = index.columns[1]
        let col3 = index.columns[2]
        
        XCTAssertEqual(col1.column, "column1")
        XCTAssertTrue(col1.ascending)
        
        XCTAssertEqual(col2.column, "column2")
        XCTAssertFalse(col2.ascending)
        
        XCTAssertEqual(col3.column, "column3")
        XCTAssertTrue(col3.ascending)
    }
}
