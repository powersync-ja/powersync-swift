import Foundation
import PowerSyncKotlin

public protocol ColumnProtocol: Equatable {
    /// Name of the column.
    var name: String { get }
    /// Type of the column.
    ///
    /// If the underlying data does not match this type,
    /// it is cast automatically.
    ///
    /// For details on the cast, see:
    ///  https://www.sqlite.org/lang_expr.html#castexpr
    ///
    var type: ColumnData { get }
}

public enum ColumnData {
    case text
    case integer
    case real
}

/// A single column in a table schema.
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
