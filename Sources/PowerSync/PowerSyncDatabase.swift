import Foundation

/// Default database filename
public let DEFAULT_DB_FILENAME = "powersync.db"

/// Creates a PowerSyncDatabase instance
/// - Parameters:
///   - schema: The database schema
///   - dbFilename: The database filename. Defaults to "powersync.db"
///   - dbDirectory: Optional custom directory path for the database file.
///     When `nil`, the database is stored in the default application support directory.
///     Use this to store the database in a shared App Group container, e.g.:
///     ```swift
///     let containerURL = FileManager.default.containerURL(
///         forSecurityApplicationGroupIdentifier: "group.com.example.app"
///     )
///     let dbDirectory = containerURL?.path
///     ```
///   - logger: Optional logging interface
///   - initialStatements: An optional list of statements to run as the database is opened.
/// - Returns: A configured PowerSyncDatabase instance
public func PowerSyncDatabase(
    schema: Schema,
    dbFilename: String = DEFAULT_DB_FILENAME,
    dbDirectory: String? = nil,
    logger: (any LoggerProtocol) = DefaultLogger(),
    initialStatements: [String] = []
) -> PowerSyncDatabaseProtocol {
    return openKotlinDBDefault(
        schema: schema,
        dbFilename: dbFilename,
        dbDirectory: dbDirectory,
        logger: DatabaseLogger(logger),
        initialStatements: initialStatements
    )
}

/// Opens a PowerSync database using an existing SQLite connection pool.
///
/// - Parameters:
///   - schema: The database schema describing the tables, indexes and other
///     structure required by PowerSync.
///   - pool: An active `SQLiteConnectionPoolProtocol` that provides connections
///     to the underlying SQLite database. The pool must remain valid for the
///     lifetime of the returned database instance.
///   - identifier: A unique identifier for this database instance. This is
///     typically used to isolate multiple database
///     instances in the same process.
///   - logger: Optional logging implementation. Defaults to `DefaultLogger()`.
///
/// - Returns: A `PowerSyncDatabaseProtocol` that wraps the opened database and
///   exposes PowerSync functionality backed by the provided connection pool.
public func OpenedPowerSyncDatabase(
    schema: Schema,
    pool: any SQLiteConnectionPoolProtocol,
    identifier: String,
    logger: (any LoggerProtocol) = DefaultLogger()
) -> PowerSyncDatabaseProtocol {
    return openKotlinDBWithPool(
        schema: schema,
        pool: pool,
        identifier: identifier,
        logger: DatabaseLogger(logger)
    )
}
