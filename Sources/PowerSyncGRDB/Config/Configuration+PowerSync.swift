import Foundation
import GRDB
import PowerSync
import SQLite3

public extension Configuration {
    /// Configures GRDB to work with PowerSync by registering required extensions and schema sources.
    ///
    /// Call this method on your existing GRDB `Configuration` to:
    /// - Register the PowerSync SQLite core extension (required for PowerSync features).
    /// - Add PowerSync schema views to your database schema source.
    ///
    /// This enables PowerSync replication and view management in your GRDB database.
    ///
    /// Example usage:
    /// ```swift
    /// var config = Configuration()
    /// try config.configurePowerSync(schema: mySchema)
    /// let dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
    /// ```
    ///
    /// - Parameter schema: The PowerSync `Schema` describing your sync views.
    /// - Throws: An error if the PowerSync extension path cannot be resolved,
    ///   if extension loading cannot be enabled, or if the PowerSync extension
    ///   fails to load or initialize.
    mutating func configurePowerSync(
        schema: Schema
    ) throws {
        // Handles the case on WatchOS where the extension is statically loaded.
        // For WatchOS: We need to statically register the extension before SQLite connections are established.
        // This should only throw on non-WatchOS platforms if the extension path cannot be resolved.
        let extensionPath = try resolvePowerSyncLoadableExtensionPath()

        // Register the PowerSync core extension
        prepareDatabase { database in
            if let extensionPath = extensionPath {
                /// The extension is loaded as an automatic extension if resolvePowerSyncLoadableExtensionPath returns nil
                /// We should dynamically load the extension if we received an extensionPath
                let extensionLoadResult = sqlite3_enable_load_extension(database.sqliteConnection, 1)
                if extensionLoadResult != SQLITE_OK {
                    throw PowerSyncGRDBError.extensionLoadFailed("Could not enable extension loading")
                }
                var errorMsg: UnsafeMutablePointer<Int8>?
                let loadResult = sqlite3_load_extension(database.sqliteConnection, extensionPath, "sqlite3_powersync_init", &errorMsg)
                if loadResult != SQLITE_OK {
                    if let errorMsg = errorMsg {
                        let message = String(cString: errorMsg)
                        sqlite3_free(errorMsg)
                        throw PowerSyncGRDBError.extensionLoadFailed(message)
                    } else {
                        throw PowerSyncGRDBError.unknownExtensionLoadError
                    }
                }
            }
        }

        // Supply the PowerSync views as a SchemaSource
        let powerSyncSchemaSource = PowerSyncSchemaSource(
            schema: schema
        )
        if let schemaSource = schemaSource {
            self.schemaSource = powerSyncSchemaSource.then(schemaSource)
        } else {
            schemaSource = powerSyncSchemaSource
        }
    }
}
