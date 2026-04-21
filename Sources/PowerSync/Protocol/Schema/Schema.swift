public protocol SchemaProtocol: Sendable {
    ///
    /// Tables used in Schema
    ///
    var tables: [Table] { get }

    /// Raw tables referenced in the schema.
    var rawTables: [RawTable] { get }
    ///
    /// Validate tables
    ///
    func validate() throws
}

public struct Schema: SchemaProtocol, Encodable {
    public let tables: [Table]
    public let rawTables: [RawTable]

    public init(tables: [Table], rawTables: [RawTable] = []) {
        self.tables = tables
        self.rawTables = rawTables
    }
    
    init(other: SchemaProtocol) {
        self.tables = other.tables
        self.rawTables = other.rawTables
    }

    ///
    /// Convenience initializer with variadic parameters
    ///
    public init(_ tables: BaseTableProtocol...) {
        var managedTables: [Table] = []
        var rawTables: [RawTable] = []

        for table in tables {
            if let table = table as? Table {
                managedTables.append(table)
            } else if let rawTable = table as? RawTable {
                rawTables.append(rawTable)
            } else {
                fatalError("BaseTableProtocol must only be implemented in Swift SDK")
            }
        }

        self.init(tables: managedTables, rawTables: rawTables)
    }

    public func validate() throws {
        var tableNames = Set<String>()

        for table in tables {
            if !tableNames.insert(table.name).inserted {
                throw SchemaError.duplicateTableName(table.name)
            }
            try table.validate()
        }
        
        for table in rawTables {
            // Only check for duplicate names if the raw table has a fixed local schema
            // name. By default, the name in raw tables refers to the name of the table as
            // defined in Sync Streams. The local table populated by put/delete statements
            // might be different and we can't check that.
            if let schema = table.schema {
                let name = schema.tableName ?? table.name
                if !tableNames.insert(name).inserted {
                    throw SchemaError.duplicateTableName(name)
                }
            }
            
            try table.validate()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        enum CodingKeys: String, CodingKey {
            case tables
            case rawTables = "raw_tables"
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.tables, forKey: .tables)
        try container.encode(self.rawTables, forKey: .rawTables)
    }
}

public enum SchemaError: Error {
    case duplicateTableName(String)
}
