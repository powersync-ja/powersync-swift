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
    /// let dbQueue = try DatabasePool(path: dbPath, configuration: config)
    /// ```
    ///
    /// - Parameter schema: The PowerSync `Schema` describing your sync views.
    /// - Throws: An error if the PowerSync extension path cannot be resolved,
    ///   if extension loading cannot be enabled, or if the PowerSync extension
    ///   fails to load or initialize.
    mutating func configurePowerSync(
        schema: Schema
    ) throws {
        // This calls sqlite3_auto_extension and enables the PowerSync core extension for all
        // new connections.
        let extensionPath = try resolvePowerSyncLoadableExtensionPath()
        assert(extensionPath == nil)

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
