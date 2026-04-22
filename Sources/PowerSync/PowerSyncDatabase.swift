import Foundation

/// Default database filename
public let DEFAULT_DB_FILENAME = "powersync.db"

/// Creates a PowerSyncDatabase instance
/// - Parameters:
///   - schema: The database schema
///   - dbFilename: The database filename. Defaults to "powersync.db"
///   - logger: Optional logging interface
///   - initialStatements: An optional list of statements to run as the database is opened.
/// - Returns: A configured PowerSyncDatabase instance
public func PowerSyncDatabase(
    schema: Schema,
    dbFilename: String = DEFAULT_DB_FILENAME,
    logger: (any LoggerProtocol) = DefaultLogger(),
    initialStatements: [String] = []
) -> PowerSyncDatabaseProtocol {
    let location = if dbFilename == ":memory:" {
        DatabaseLocation.inMemory
    } else {
        DatabaseLocation.inDefaultDirectory(name: dbFilename)
    }
    let pool = AsyncConnectionPool(location: location, initialStatements: initialStatements)
    return PowerSyncDatabaseImpl(
        dbFilename: dbFilename,
        logger: logger,
        pool: pool,
        httpClient: PlatformHttpClient.shared,
        schema: schema
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
    return PowerSyncDatabaseImpl(
        logger: logger,
        pool: pool,
        httpClient: PlatformHttpClient.shared,
        schema: schema
    )
}
