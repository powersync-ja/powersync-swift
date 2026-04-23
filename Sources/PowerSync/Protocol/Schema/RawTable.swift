import Foundation

/// A table that is managed by the user instead of being auto-created and migrated by the PowerSync SDK.
///
/// These tables give application developers full control over the table (including table and column constraints).
/// The ``RawTable/put`` and ``RawTable/delete`` statements used by the sync client to apply
/// operations to the local database also need to be set explicitly.
///
/// A main benefit of raw tables is that, since they're not backed by JSON views, complex queries on them
/// can be much more efficient.
/// However, it's the responsibility of the developer to create these raw tables, migrate them when necessary
/// and to write triggers detecting local writes. For more information, see [the documentation](https://docs.powersync.com/usage/use-case-examples/raw-tables).
///
/// Note that raw tables are only supported when ``ConnectOptions/newClientImplementation``
/// is enabled.
public struct RawTable: BaseTableProtocol, Encodable {
    /// The name of the table as it appears in sync rules.
    ///
    /// This doesn't necessarily have to match the statement that ``RawTable/put`` and ``RawTable/delete``
    /// write into.
    /// Instead, it is used by the sync client to identify which operations need to use which raw table definition.
    public let name: String

    public let schema: RawTableSchema?

    /// The statement to run when the sync client has to insert or update a row.
    public let put: PendingStatement?

    /// The statement to run when the sync client has to delete a row.
    public let delete: PendingStatement?
    
    /// An optional statement to run when the database is cleared.
    public let clear: String?

    /// Creates a raw table from explicit `put` and `delete` statements.
    /// 
    /// Alternatively, raw tables can also be constructed with a ``RawTableSchema`` to infer those statements.
    public init(name: String, put: PendingStatement, delete: PendingStatement, clear: String? = nil) {
        self.name = name
        self.schema = nil
        self.put = put
        self.delete = delete
        self.clear = clear
    }

    /// Creates a raw table where `put` and `delete` statements for the sync client are inferred from a
    /// ``RawTableSchema``.
    /// 
    /// The statements can still be customized if necessary.
    public init(name: String, schema: RawTableSchema, put: PendingStatement? = nil, delete: PendingStatement? = nil, clear: String? = nil) {
        self.name = name
        self.schema = schema
        self.put = put
        self.delete = delete
        self.clear = clear
    }

    /// A JSON-serialized representation of this raw table.
    /// 
    /// The output of this can be passed to the `powersync_create_raw_table_crud_trigger` SQL
    /// function to define triggers for this table.
    public func jsonDescription() -> String {
        let encoder = JSONEncoder()
        do {
            let serialized = try encoder.encode(self)
            return String(data: serialized, encoding: .utf8)!
        } catch {
            // An older version of the Swift SDK used to implement this method in Kotlin.
            // That could also throw an exception (which would crash the process), but that
            // was overlooked due to a missing @Throws annotation.
            // Now, we can't mark this as throws without breaking backwards compatibility.
            // We should convert this to be throwing in a future major release.
            fatalError("Serializing a raw table failed: \(error)")
        }
    }

    internal func validate() throws(TableError) {
        if let schema {
            try schema.options.validate(tableName: name)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        enum CodingKeys: String, CodingKey {
            case name
            case put
            case delete
            case clear
            // For schema
            case tableName = "table_name"
            case syncedColumns = "synced_columns"
        }
        typealias Keys = TableOptionsCodingKeys<CodingKeys>

        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(name, forKey: .outer(.name))
        try container.encodeIfPresent(put, forKey: .outer(.put))
        try container.encodeIfPresent(delete, forKey: .outer(.delete))
        try container.encodeIfPresent(clear, forKey: .outer(.clear))
        if let schema {
            try container.encode(schema.tableName ?? name, forKey: .outer(.tableName))
            try container.encodeIfPresent(schema.syncedColumns, forKey: .outer(.syncedColumns))
            try schema.options.serializeTo(container)
        }
    }
}

/// The schema of a ``RawTable`` in the local database.
/// 
/// This information is optional when declaring raw tables. However, providing it allows the sync
/// client to infer ``RawTable/put`` and ``RawTable/delete`` statements automatically.
public struct RawTableSchema: Sendable {
    /// The actual name of the raw table in the local schema.
    /// 
    /// Unlike ``RawTable/name``, which describes the name of synced tables to match, this reflects
    /// the SQLite table name. This is used to infer ``RawTable/put`` and ``RawTable/delete`` statements
    /// for the sync client. It can also be used to auto-generate triggers forwarding writes on raw
    /// tables into the CRUD upload queue (using the `powersync_create_raw_table_crud_trigger` SQL function).
    /// 
    /// When set to `nil`, ``RawTable/name`` is used as a default.
    public let tableName: String?

    /// An optional filter of columns that should be synced.
    /// 
    /// By default, all columns in a raw table are considered for sync. If a filter is specified,
    /// PowerSync treats unmatched columns as local-only and will not attempt to sync them.
    public let syncedColumns: [String]?
    
    /// Common options affecting how the `powersync_create_raw_table_crud_trigger` SQL function generates
    /// triggers.
    public let options: TableOptions

    public init(tableName: String? = nil, syncedColumns: [String]? = nil, options: TableOptions = TableOptions()) {
        self.tableName = tableName
        self.syncedColumns = syncedColumns
        self.options = options
    }
}

/// A statement to run to sync server-side changes into a local raw table.
public struct PendingStatement: Sendable, Encodable {
    /// The SQL statement to execute.
    public let sql: String
    /// For parameters in the prepared statement, the values to fill in.
    ///
    /// Note that the ``RawTable/delete`` statement can only use ``PendingStatementParameter/id`` - upsert
    /// statements can also use ``PendingStatementParameter/column`` to refer to columns.
    public let parameters: [PendingStatementParameter]

    public init(sql: String, parameters: [PendingStatementParameter]) {
        self.sql = sql
        self.parameters = parameters
    }

    public func encode(to encoder: any Encoder) throws {
        enum CodingKeys: String, CodingKey {
            case sql
            case parameters = "params"
         }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.sql, forKey: .sql)
        try container.encode(self.parameters, forKey: .parameters)
    }
}

/// A parameter that can be used in a ``PendingStatement``.
public enum PendingStatementParameter: Sendable, Encodable {
    /// A value that resolves to the textual id of the row to insert, update or delete.
    case id
    /// A value that resolves to the value of a column in a `PUT` operation for inserts or updates.
    ///
    /// Note that using this parameter is not allowed for ``RawTable/delete`` statements, which only have access
    /// to the row's ``PendingStatementParameter/id``.
    case column(String)
    /// Resolves to a JSON object containing all columns from the synced row that haven't been matched
    /// by a ``PendingStatementParameter/column`` value in the same statement.
    case rest

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .id:
            var container = encoder.singleValueContainer()
            try container.encode("Id")
        case .column(let name):
            enum CodingKeys: String, CodingKey {
                case column = "Column"
            }

            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .column)
        case .rest:
            var container = encoder.singleValueContainer()
            try container.encode("Rest")
        }
    }
}
