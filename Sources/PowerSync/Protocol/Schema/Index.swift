import Foundation

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
    
    internal func encode(table: borrowing Table, to: any UnkeyedEncodingContainer) throws {
        enum CodingKeys: CodingKey {
            case name
            case columns
        }

        var to = to
        var container = to.nestedContainer(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        var columnsContainer = container.nestedUnkeyedContainer(forKey: .columns)
        for column in columns {
            enum IndexedColumnCodingKeys: CodingKey {
                case name
                case ascending
                case type
            }

            var container = columnsContainer.nestedContainer(keyedBy: IndexedColumnCodingKeys.self)
            try container.encode(column.column, forKey: .name)
            try container.encode(column.ascending, forKey: .ascending)
            guard let tableColumn = table.columns.first(where: { c in c.name == column.column }) else {
                throw PowerSyncError.operationFailed(message: "Unserializable schema: Index \(self.name) references column \(column.column) which does not exist in \(table.name)")
            }

            try container.encode(tableColumn.type, forKey: .type)
        }
    }
}
