import XCTest
@testable import PowerSync

final class IndexedColumnTests: XCTestCase {
    
    func testBasicInitialization() {
        let column = IndexedColumn(column: "test", ascending: true)
        
        XCTAssertEqual(column.column, "test")
        XCTAssertTrue(column.ascending)
    }
    
    func testDefaultAscendingValue() {
        let column = IndexedColumn(column: "test")
        XCTAssertTrue(column.ascending)
    }
    
    func testDescendingInitialization() {
        let column = IndexedColumn(column: "test", ascending: false)
        
        XCTAssertEqual(column.column, "test")
        XCTAssertFalse(column.ascending)
    }
    
    func testIgnoresOptionalParameters() {
        let column = IndexedColumn(
            column: "test",
            ascending: true
        )
        
        XCTAssertEqual(column.column, "test")
        XCTAssertTrue(column.ascending)
    }
    
    func testAscendingFactory() {
        let column = IndexedColumn.ascending("test")
        
        XCTAssertEqual(column.column, "test")
        XCTAssertTrue(column.ascending)
    }
    
    func testDescendingFactory() {
        let column = IndexedColumn.descending("test")
        
        XCTAssertEqual(column.column, "test")
        XCTAssertFalse(column.ascending)
    }
    
    func testMultipleInstances() {
        let columns = [
            IndexedColumn.ascending("first"),
            IndexedColumn.descending("second"),
            IndexedColumn(column: "third")
        ]
        
        XCTAssertEqual(columns[0].column, "first")
        XCTAssertTrue(columns[0].ascending)
        
        XCTAssertEqual(columns[1].column, "second")
        XCTAssertFalse(columns[1].ascending)
        
        XCTAssertEqual(columns[2].column, "third")
        XCTAssertTrue(columns[2].ascending)
    }
}
