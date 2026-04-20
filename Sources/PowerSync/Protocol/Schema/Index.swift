import Foundation
import PowerSyncKotlin

public protocol IndexProtocol: Sendable {
    ///
    /// Descriptive name of the index.
    ///
    var name: String { get }
    ///
    /// List of columns used for the index.
    ///
    var columns: [IndexedColumnProtocol] { get }
}

public struct Index: IndexProtocol, Encodable {
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
    
    public func encode(to encoder: any Encoder) throws {
        enum CodingKeys: CodingKey {
            case name
            case columns
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        var columnsContainer = container.nestedUnkeyedContainer(forKey: .columns)
        for column in columns {
            enum CodingKeys: CodingKey {
                case name
                case ascending
            }

            var container = columnsContainer.nestedContainer(keyedBy: CodingKeys.self)
            try container.encode(column.column, forKey: .name)
            try container.encode(column.ascending, forKey: .ascending)
        }
    }
}
