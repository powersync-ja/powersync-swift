import Foundation
import PowerSync

public protocol IndexProtocol {
    var name: String { get }
    var columns: [IndexedColumnProtocol] { get }
}

public struct Index: IndexProtocol {
    public let name: String
    public let columns: [IndexedColumnProtocol]
    
    public init(
        name: String,
        columns: [IndexedColumnProtocol]
    ) {
        self.name = name
        self.columns = columns
    }
    
    public init(
        name: String,
        _ columns: IndexedColumnProtocol...
    ) {
        self.init(name: name, columns: columns)
    }
    
    public static func ascending(
        name: String,
        columns: [String]
    ) -> Index {
        return Index(
            name: name,
            columns: columns.map { IndexedColumn.ascending($0) }
        )
    }
    
    public static func ascending(
        name: String,
        column: String
    ) -> Index {
        return ascending(name: name, columns: [column])
    }
}
