import PowerSync
import SwiftData

/// Configures a ``PowerSyncDataStore`` for use with a SwiftData `ModelContainer`.
///
/// The application owns the `PowerSyncDatabase` (and its sync connection); this configuration
/// merely points the store at it:
///
/// ```swift
/// let database = PowerSyncDatabase(schema: appSchema)
/// let configuration = PowerSyncDataStoreConfiguration(
///     name: "powersync",
///     database: database
/// )
/// let container = try ModelContainer(
///     for: SwiftData.Schema([Note.self]),
///     configurations: [configuration]
/// )
/// ```
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
public final class PowerSyncDataStoreConfiguration: DataStoreConfiguration {
    public typealias Store = PowerSyncDataStore

    /// Identifies the store. Persistent identifiers minted by the store embed this name.
    public let name: String

    /// The SwiftData schema. `ModelContainer` injects this before creating the store.
    public var schema: SwiftData.Schema?

    /// The PowerSync database backing the store. PowerSync owns the SQLite connection and
    /// the upload queue; the store never opens a second connection.
    public let database: any PowerSyncDatabaseProtocol

    /// Maps a SwiftData entity name to the PowerSync table (view) name.
    /// Defaults to ``defaultTableName(forEntityName:)``.
    public let tableNameForEntity: @Sendable (String) -> String

    /// Maps `(entityName, propertyName)` to a PowerSync column name, or `nil` to keep the
    /// default (the property name; to-one relationships append `_id` to the result).
    /// Lets camelCase Swift properties map to snake_case backend columns.
    public let columnNameForProperty: @Sendable (String, String) -> String?

    /// The `ModelContext.author` used by ``PowerSyncChangeObserver`` when re-injecting
    /// changes that arrived from PowerSync. Saves authored this way are echo-suppressed:
    /// the store does not write them back to the database.
    public let remoteAuthor: String

    /// When `true`, the store refuses every write with `DataStoreError.unsupportedFeature`.
    /// Optional hardening for display-only widgets and extensions; writes from extension
    /// processes are otherwise fully supported (persisted, queued for upload, and signaled
    /// to the app's live queries).
    public let readOnly: Bool

    /// Test-only hook: remaps snapshot value keys when building snapshots from fetched rows.
    /// Used to prove that SwiftData materializes models by property *name*.
    var _testFetchKeyTransform: (@Sendable (String) -> String)?

    public init(
        name: String,
        database: any PowerSyncDatabaseProtocol,
        schema: SwiftData.Schema? = nil,
        tableNameForEntity: @escaping @Sendable (String) -> String = PowerSyncDataStoreConfiguration.defaultTableName(forEntityName:),
        columnNameForProperty: @escaping @Sendable (String, String) -> String? = { _, _ in nil },
        remoteAuthor: String = "powersync-remote",
        readOnly: Bool = false
    ) {
        self.name = name
        self.database = database
        self.schema = schema
        self.tableNameForEntity = tableNameForEntity
        self.columnNameForProperty = columnNameForProperty
        self.remoteAuthor = remoteAuthor
        self.readOnly = readOnly
    }

    /// Converts an entity name to `snake_case`, the conventional PowerSync table naming.
    /// `Note` becomes `note`; `TodoItem` becomes `todo_item`.
    public static func defaultTableName(forEntityName entityName: String) -> String {
        var result = ""
        var previousWasLowercase = false
        for character in entityName {
            if character.isUppercase {
                if previousWasLowercase {
                    result.append("_")
                }
                result.append(contentsOf: character.lowercased())
                previousWasLowercase = false
            } else {
                result.append(character)
                previousWasLowercase = character.isLowercase
            }
        }
        return result
    }

    public static func == (lhs: PowerSyncDataStoreConfiguration, rhs: PowerSyncDataStoreConfiguration) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
