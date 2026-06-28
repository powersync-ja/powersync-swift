import Foundation

/// Default database filename
public let DEFAULT_DB_FILENAME = "powersync.db"

/// Creates a PowerSyncDatabase instance
/// - Parameters:
///   - schema: The database schema
///   - dbFilename: The database filename. Defaults to "powersync.db". Plain names are
///     stored in the default databases directory; an absolute path (starting with "/") is
///     used as-is, which allows sharing the database with app extensions through an App
///     Group container. The database itself can be used concurrently from the main app and
///     its extensions, but only the main app should call `connect`. Two sync connections on
///     the same database waste resources and are untested (and could corrupt the sync
///     client); let extensions read and write, and leave syncing to the app.
///   - logger: Optional logging interface
///   - initialStatements: An optional list of statements to run as the database is opened.
/// - Returns: A configured PowerSyncDatabase instance
public func PowerSyncDatabase(
    schema: Schema,
    dbFilename: String = DEFAULT_DB_FILENAME,
    logger: (any LoggerProtocol) = DefaultLogger(),
    initialStatements: [String] = []
) -> PowerSyncDatabaseProtocol {
    let (location, group) = if dbFilename == ":memory:" {
        (DatabaseLocation.inMemory, DatabaseGroupCollection())
    } else if dbFilename.hasPrefix("/") {
        (DatabaseLocation.atPath(dbFilename), .shared)
    } else {
        (DatabaseLocation.inDefaultDirectory(name: dbFilename), .shared)
    }
    let pool = AsyncConnectionPool(location: location, logger: logger, initialStatements: initialStatements)
    return PowerSyncDatabaseImpl(
        dbFilename: dbFilename,
        identifier: dbFilename,
        activeInstanceStore: group,
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
        identifier: identifier,
        logger: logger,
        pool: pool,
        httpClient: PlatformHttpClient.shared,
        schema: schema
    )
}
