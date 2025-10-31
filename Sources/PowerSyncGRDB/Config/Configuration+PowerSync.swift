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
    /// config.configurePowerSync(schema: mySchema)
    /// let dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
    /// ```
    ///
    /// - Parameter schema: The PowerSync `Schema` describing your sync views.
    mutating func configurePowerSync(
        schema: Schema
    ) {
        // Register the PowerSync core extension
        prepareDatabase { database in
            #if os(watchOS)
                // Use static initialization on watchOS
                let initResult = sqlite3_powersync_init(database.sqliteConnection, nil, nil)
                if initResult != SQLITE_OK {
                    throw PowerSyncGRDBError.extensionLoadFailed("Could not initialize PowerSync statically")
                }
            #else
                // Dynamic loading on other platforms
                guard let bundle = Bundle(identifier: "co.powersync.sqlitecore") else {
                    throw PowerSyncGRDBError.coreBundleNotFound
                }

                // Construct the full path to the shared library inside the bundle
                let fullPath = bundle.bundlePath + "/powersync-sqlite-core"

                let extensionLoadResult = sqlite3_enable_load_extension(database.sqliteConnection, 1)
                if extensionLoadResult != SQLITE_OK {
                    throw PowerSyncGRDBError.extensionLoadFailed("Could not enable extension loading")
                }
                var errorMsg: UnsafeMutablePointer<Int8>?
                let loadResult = sqlite3_load_extension(database.sqliteConnection, fullPath, "sqlite3_powersync_init", &errorMsg)
                if loadResult != SQLITE_OK {
                    if let errorMsg = errorMsg {
                        let message = String(cString: errorMsg)
                        sqlite3_free(errorMsg)
                        throw PowerSyncGRDBError.extensionLoadFailed(message)
                    } else {
                        throw PowerSyncGRDBError.unknownExtensionLoadError
                    }
                }
            #endif
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
