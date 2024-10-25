import Foundation
import PowerSync

public protocol ColumnProtocol: Equatable {
    var name: String { get }
    var type: ColumnData { get }
}

public enum ColumnData {
    case text
    case integer
    case real
}

public struct Column: ColumnProtocol {
    public let name: String
    public let type: ColumnData
    
    public init(
        name: String,
        type: ColumnData
    ) {
        self.name = name
        self.type = type
    }
    
    public static func text(_ name: String) -> Column {
        Column(name: name, type: .text)
    }
    
    public static func integer(_ name: String) -> Column {
        Column(name: name, type: .integer)
    }
    
    public static func real(_ name: String) -> Column {
        Column(name: name, type: .real)
    }
}
