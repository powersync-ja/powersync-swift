public protocol SchemaProtocol {
    var tables: [Table] { get }
    func validate() throws
}

public struct Schema: SchemaProtocol {
    public let tables: [Table]
    
    public init(tables: [Table]) {
        self.tables = tables
    }
    
    // Convenience initializer with variadic parameters
    public init(_ tables: Table...) {
        self.init(tables: tables)
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

