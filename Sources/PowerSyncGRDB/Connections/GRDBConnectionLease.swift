import Foundation
import GRDB
import PowerSync

/// Internal lease object that exposes the raw GRDB SQLite connection pointer.
///
/// This is used to bridge GRDB's managed database connection with the Swift SDK,
/// allowing direct access to the underlying SQLite connection for PowerSync operations.
final class GRDBConnectionLease: SQLiteConnectionLease {
    let pointer: OpaquePointer
    var database: Database

    init(database: Database) throws {
        guard let connection = database.sqliteConnection else {
            throw PowerSyncGRDBError.connectionUnavailable
        }
        self.pointer = connection
        self.database = database
    }
}

extension PowerSync.PowerSyncDataType: DatabaseValueConvertible {
    public var databaseValue: GRDB.DatabaseValue {
        switch self {
        case .bool(let value):
            return value.databaseValue
        case .string(let value):
            return value.databaseValue
        case .int64(let value):
            return value.databaseValue
        case .int32(let value):
            return value.databaseValue
        case .double(let value):
            return value.databaseValue
        case .data(let value):
            return value.databaseValue
        }
    }

    public static func fromDatabaseValue(_ dbValue: GRDB.DatabaseValue) -> PowerSync.PowerSyncDataType? {
        nil
    }
}
