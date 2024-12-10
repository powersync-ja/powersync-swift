import XCTest
@testable import PowerSync

final class ColumnTests: XCTestCase {
    
    func testColumnInitialization() {
        let name = "testColumn"
        let type = ColumnData.text
        
        let column = Column(name: name, type: type)
        
        XCTAssertEqual(column.name, name)
        XCTAssertEqual(column.type, type)
    }
    
    func testTextColumnFactory() {
        let name = "textColumn"
        let column = Column.text(name)
        
        XCTAssertEqual(column.name, name)
        XCTAssertEqual(column.type, .text)
    }
    
    func testIntegerColumnFactory() {
        let name = "intColumn"
        let column = Column.integer(name)
        
        XCTAssertEqual(column.name, name)
        XCTAssertEqual(column.type, .integer)
    }
    
    func testRealColumnFactory() {
        let name = "realColumn"
        let column = Column.real(name)
        
        XCTAssertEqual(column.name, name)
        XCTAssertEqual(column.type, .real)
    }
        
    func testEmptyColumnName() {
        let column = Column(name: "", type: .text)
        XCTAssertEqual(column.name, "")
    }
    
    func testColumnDataTypeEquality() {
        XCTAssertEqual(ColumnData.text, ColumnData.text)
        XCTAssertEqual(ColumnData.integer, ColumnData.integer)
        XCTAssertEqual(ColumnData.real, ColumnData.real)
        
        XCTAssertNotEqual(ColumnData.text, ColumnData.integer)
        XCTAssertNotEqual(ColumnData.text, ColumnData.real)
        XCTAssertNotEqual(ColumnData.integer, ColumnData.real)
    }
    
    func testMultipleColumnCreation() {
        let columns = [
            Column.text("name"),
            Column.integer("age"),
            Column.real("score")
        ]
        
        XCTAssertEqual(columns[0].type, .text)
        XCTAssertEqual(columns[1].type, .integer)
        XCTAssertEqual(columns[2].type, .real)
    }
}
