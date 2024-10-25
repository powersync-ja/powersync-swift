import Foundation

/// Default database filename
public let DEFAULT_DB_FILENAME = "powersync.db"

/// Creates a PowerSyncDatabase instance
/// - Parameters:
///   - schema: The database schema
///   - dbFilename: The database filename. Defaults to "powersync.db"
/// - Returns: A configured PowerSyncDatabase instance
@MainActor
public func PowerSyncDatabase(
    schema: Schema,
    dbFilename: String = DEFAULT_DB_FILENAME
) -> PowerSyncDatabaseProtocol {
    
    return KotlinPowerSyncDatabaseImpl(
        schema: schema,
        dbFilename: dbFilename
    )
}
