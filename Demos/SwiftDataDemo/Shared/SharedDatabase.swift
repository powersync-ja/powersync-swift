import Foundation
import PowerSync
import PowerSyncSwiftData
import SwiftData

/// Shared constants and helpers used by both the app and the widget extension.
///
/// The PowerSync database file lives in the App Group container so the widget process can
/// open (and read) the exact same file the app writes and syncs.
enum SharedDatabase {
    /// The App Group both targets belong to.
    static let appGroupID = "group.co.powersync.swiftdatademo"

    /// The SwiftData models persisted through PowerSync. The PowerSync schema (tables
    /// `todo_list` and `todo`) is derived from these with `PowerSyncSchema(for:)`.
    static let models: [any PersistentModel.Type] = [TodoList.self, Todo.self]

    /// Absolute path to the PowerSync database file inside the App Group container.
    ///
    /// `PowerSyncDatabase(dbFilename:)` treats a filename starting with "/" as an absolute
    /// path and uses it as-is, which is what allows the app and the widget to share a file
    /// outside the app sandbox's default database directory.
    static var databasePath: String {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            fatalError("App Group \(appGroupID) is not configured for this target.")
        }
        return container.appendingPathComponent("powersync.db").path
    }

    /// Opens the PowerSync database over the shared App Group file, deriving the PowerSync
    /// schema from the SwiftData models.
    static func openDatabase() throws -> any PowerSyncDatabaseProtocol {
        PowerSyncDatabase(
            schema: try PowerSyncSchema(for: models),
            dbFilename: databasePath
        )
    }
}
