import GRDB
import PowerSync

/// Creates a PowerSync database instance that integrates with an existing GRDB database pool.
///
/// Use this function to initialize PowerSync with a GRDB database:
/// ```swift
/// // Define your PowerSync schema
/// let schema = Schema(
///     tables: [
///         Table(
///             name: "users",
///             columns: [
///                 .text("name"),
///                 .integer("age"),
///                 .text("email")
///             ]
///         )
///     ]
/// )
///
/// // Configure GRDB with PowerSync support
/// var config = Configuration()
/// config.configurePowerSync(schema: schema)
///
/// // Create the database pool
/// let dbPool = try DatabasePool(path: "path/to/db", configuration: config)
///
/// // Initialize PowerSync with GRDB
/// let powerSync = try openPowerSyncWithGRDB(
///     pool: dbPool,
///     schema: schema,
///     identifier: "app-db"
/// )
/// ```
///
/// - Parameters:
///   - pool: The GRDB DatabasePool instance to use for storage
///   - schema: The PowerSync schema describing your sync views
///   - identifier: A unique identifier for this database instance
/// - Returns: A PowerSync database that works with the provided GRDB pool
public func openPowerSyncWithGRDB(
    pool: DatabasePool,
    schema: Schema,
    identifier: String
) -> PowerSyncDatabaseProtocol {
    return OpenedPowerSyncDatabase(
        schema: schema,
        pool: GRDBConnectionPool(
            pool: pool
        ),
        identifier: identifier
    )
}
