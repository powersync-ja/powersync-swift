public protocol SchemaProtocol {
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

public struct Schema: SchemaProtocol {
    public let tables: [Table]
    public let rawTables: [RawTable]

    public init(tables: [Table], rawTables: [RawTable] = []) {
        self.tables = tables
        self.rawTables = rawTables
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
    }
}

public enum SchemaError: Error {
    case duplicateTableName(String)
}
