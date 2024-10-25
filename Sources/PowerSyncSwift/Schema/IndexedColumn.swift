import Foundation

public protocol IndexedColumnProtocol {
    var column: String { get }
    var ascending: Bool { get }
}

public struct IndexedColumn: IndexedColumnProtocol {
    public let column: String
    public let ascending: Bool
    
    public init(
        column: String,
        ascending: Bool = true
    ) {
        self.column = column
        self.ascending = ascending
    }
    
    public static func ascending(_ column: String) -> IndexedColumn {
        IndexedColumn(column: column, ascending: true)
    }
    
    public static func descending(_ column: String) -> IndexedColumn {
        IndexedColumn(column: column, ascending: false)
    }
}
