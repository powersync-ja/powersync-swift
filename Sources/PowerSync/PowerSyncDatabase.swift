import Foundation

/// Default database filename
public let DEFAULT_DB_FILENAME = "powersync.db"

/// Creates a PowerSyncDatabase instance
/// - Parameters:
///   - schema: The database schema
///   - dbFilename: The database filename. Defaults to "powersync.db"
///   - logger: Optional logging interface
/// - Returns: A configured PowerSyncDatabase instance
public func PowerSyncDatabase(
    schema: Schema,
    dbFilename: String = DEFAULT_DB_FILENAME,
    logger: (any LoggerProtocol) = DefaultLogger()
) -> PowerSyncDatabaseProtocol {
    
    return KotlinPowerSyncDatabaseImpl(
        schema: schema,
        dbFilename: dbFilename,
        logger: DatabaseLogger(logger)
    )
}
