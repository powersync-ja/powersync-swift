import Foundation

public protocol ColumnProtocol: Equatable, Sendable {
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

public enum ColumnData: Sendable, Encodable {
    case text
    case integer
    case real
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text:
            try container.encode("text")
        case .integer:
            try container.encode("integer")
        case .real:
            try container.encode("real")
        }
    }
}

/// A single column in a table schema.
public struct Column: ColumnProtocol, Encodable {
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
