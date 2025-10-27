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
public struct RawTable: BaseTableProtocol {
    /// The name of the table as it appears in sync rules.
    ///
    /// This doesn't necessarily have to match the statement that ``RawTable/put`` and ``RawTable/delete``
    /// write into.
    /// Instead, it is used by the sync client to identify which operations need to use which raw table definition.
    public let name: String

    /// The statement to run when the sync client has to insert or update a row.
    public let put: PendingStatement

    /// The statement to run when the sync client has to delete a row.
    public let delete: PendingStatement
    
    /// An optional statement to run when the database is cleared.
    public let clear: String?

    public init(name: String, put: PendingStatement, delete: PendingStatement, clear: String? = nil) {
        self.name = name
        self.put = put
        self.delete = delete
        self.clear = clear
    }
}

/// A statement to run to sync server-side changes into a local raw table.
public struct PendingStatement: Sendable {
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
}

/// A parameter that can be used in a ``PendingStatement``.
public enum PendingStatementParameter: Sendable {
    /// A value that resolves to the textual id of the row to insert, update or delete.
    case id
    /// A value that resolves to the value of a column in a `PUT` operation for inserts or updates.
    ///
    /// Note that using this parameter is not allowed for ``RawTable/delete`` statements, which only have access
    /// to the row's ``PendingStatementParameter/id``.
    case column(String)
}
