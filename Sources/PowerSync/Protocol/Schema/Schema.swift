import Foundation

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
            if let schema = table.schema {
                let name = schema.tableName ?? table.name
                if !tableNames.insert(name).inserted {
                    throw SchemaError.duplicateTableName(name)
                }
            }
            
            try table.validate()
        }
    }
    
    internal static let encoder = JSONEncoder()
}

public enum SchemaError: Error {
    case duplicateTableName(String)
}
