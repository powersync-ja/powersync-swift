import Foundation
import GRDB
import PowerSync
import SQLite3

// The system SQLite does not expose this,
// linking PowerSync provides them
// Declare the missing function manually
@_silgen_name("sqlite3_enable_load_extension")
func sqlite3_enable_load_extension(
    _ db: OpaquePointer?,
    _ onoff: Int32
) -> Int32

// Similarly for sqlite3_load_extension if needed:
@_silgen_name("sqlite3_load_extension")
func sqlite3_load_extension(
    _ db: OpaquePointer?,
    _ fileName: UnsafePointer<Int8>?,
    _ procName: UnsafePointer<Int8>?,
    _ errMsg: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> Int32

enum PowerSyncGRDBError: Error {
    case coreBundleNotFound
    case extensionLoadFailed(String)
    case unknownExtensionLoadError
    case connectionUnavailable
}

struct PowerSyncSchemaSource: DatabaseSchemaSource {
    let schema: Schema

    func columnsForPrimaryKey(_: Database, inView view: DatabaseObjectID) throws -> [String]? {
        if schema.tables.first(where: { table in
            table.viewName == view.name
        }) != nil {
            return ["id"]
        }
        return nil
    }
}

func configurePowerSync(
    config: inout Configuration,
    schema: Schema
) {
    // Register the PowerSync core extension
    config.prepareDatabase { database in
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
    }

    // Supply the PowerSync views as a SchemaSource
    let powerSyncSchemaSource = PowerSyncSchemaSource(
        schema: schema
    )
    if let schemaSource = config.schemaSource {
        config.schemaSource = schemaSource.then(powerSyncSchemaSource)
    } else {
        config.schemaSource = powerSyncSchemaSource
    }
}

class GRDBConnectionPool: SQLiteConnectionPoolProtocol {
    let pool: DatabasePool

    init(
        pool: DatabasePool
    ) {
        self.pool = pool
    }

    func read(
        onConnection: @Sendable @escaping (OpaquePointer) -> Void
    ) async throws {
        try await pool.read { database in
            guard let connection = database.sqliteConnection else {
                throw PowerSyncGRDBError.connectionUnavailable
            }
            onConnection(connection)
        }
    }

    func write(
        onConnection: @Sendable @escaping (OpaquePointer) -> Void
    ) async throws {
        // Don't start an explicit transaction
        try await pool.writeWithoutTransaction { database in
            guard let connection = database.sqliteConnection else {
                throw PowerSyncGRDBError.connectionUnavailable
            }
            onConnection(connection)
        }
    }

    func withAllConnections(
        onConnection _: @escaping (OpaquePointer, [OpaquePointer]) -> Void
    ) async throws {
        // TODO:
    }

    func close() throws {
        try pool.close()
    }
}
