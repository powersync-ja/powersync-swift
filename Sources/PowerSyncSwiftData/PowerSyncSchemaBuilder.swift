import PowerSync
import SwiftData

/// Derives the PowerSync schema from SwiftData models, so the application declares its
/// `@Model`s once instead of duplicating tables and columns:
///
/// ```swift
/// let database = PowerSyncDatabase(
///     schema: try PowerSyncSchema(for: [Note.self, Playlist.self, Song.self])
/// )
/// ```
///
/// Attribute columns use the store's coercion mapping (`Date` -> `real`, `Data`/`UUID` and
/// codable values -> `text`, ...). To-one relationships become `{name}_id` text columns
/// with an index (used by the inverse to-many resolution). The implicit PowerSync `id`
/// column is never declared.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
public func PowerSyncSchema(
    for models: [any PersistentModel.Type],
    tableNameForEntity: @escaping @Sendable (String) -> String = PowerSyncDataStoreConfiguration.defaultTableName(forEntityName:),
    columnNameForProperty: @escaping @Sendable (String, String) -> String? = { _, _ in nil }
) throws -> PowerSync.Schema {
    return try PowerSyncSchema(
        for: SwiftData.Schema(models),
        tableNameForEntity: tableNameForEntity,
        columnNameForProperty: columnNameForProperty
    )
}

/// Derives the PowerSync schema from an existing SwiftData schema.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
public func PowerSyncSchema(
    for schema: SwiftData.Schema,
    tableNameForEntity: @escaping @Sendable (String) -> String = PowerSyncDataStoreConfiguration.defaultTableName(forEntityName:),
    columnNameForProperty: @escaping @Sendable (String, String) -> String? = { _, _ in nil }
) throws -> PowerSync.Schema {
    let mapper = try SchemaMapper(
        schema: schema,
        tableNameForEntity: tableNameForEntity,
        columnNameForProperty: columnNameForProperty
    )
    let tables = mapper.entitiesByName.values
        .sorted { $0.tableName < $1.tableName }
        .map { entity -> Table in
            var columns = entity.properties.filter(\.isStored).map { property in
                Column(name: property.columnName, type: ValueCoercion.columnType(for: property.kind))
            }
            var indexes: [Index] = []
            for relationship in entity.toOne {
                columns.append(.text(relationship.columnName))
                indexes.append(.ascending(name: relationship.columnName, column: relationship.columnName))
            }
            return Table(name: entity.tableName, columns: columns, indexes: indexes)
        }
    return PowerSync.Schema(tables: tables)
}
