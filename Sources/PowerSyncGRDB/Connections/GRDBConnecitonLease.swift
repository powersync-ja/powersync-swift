import Foundation
import GRDB
import PowerSync

/// Internal lease object that exposes the raw GRDB SQLite connection pointer.
///
/// This is used to bridge GRDB's managed database connection with the Kotlin SDK,
/// allowing direct access to the underlying SQLite connection for PowerSync operations.
final class GRDBConnectionLease: SQLiteConnectionLease {
    var pointer: OpaquePointer

    init(database: Database) throws {
        guard let connection = database.sqliteConnection else {
            throw PowerSyncGRDBError.connectionUnavailable
        }
        pointer = connection
    }
}
