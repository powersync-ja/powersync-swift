import PowerSync
import SwiftData
import Synchronization

/// Quotes a SQL identifier (table or column name).
func sqlQuote(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

/// How a single `@Model` stored property maps to a PowerSync column.
/// `defaultValue` is an immutable value captured from the schema, safe to share.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
struct PropertyMapping: @unchecked Sendable {
    let name: String
    let columnName: String
    let kind: ValueCoercion.Kind
    let isOptional: Bool
    /// `false` for ephemeral (transient) attributes: no column, never persisted or
    /// uploaded; materialization uses the declared default.
    let isStored: Bool
    /// The property's declared default, used when stored rows predate the property and
    /// for ephemeral attributes.
    let defaultValue: Any?
}

/// How a to-one relationship maps to a foreign-key column.
/// `AnyKeyPath` is immutable and safe to share across threads.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
struct RelationshipMapping: @unchecked Sendable {
    let name: String
    let columnName: String
    let destinationEntityName: String
    let isOptional: Bool
    let keyPath: AnyKeyPath?
    let destinationType: any PersistentModel.Type
}

/// How a to-many relationship resolves through the destination's inverse to-one column.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
struct ToManyMapping: @unchecked Sendable {
    let name: String
    let destinationEntityName: String
    let destinationTableName: String
    /// The foreign-key column on the destination table pointing back at this entity.
    let inverseColumnName: String
    let keyPath: AnyKeyPath?
    let elementType: any PersistentModel.Type
}

/// A SQL statement ready to run inside a PowerSync write transaction.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
struct SQLStatement: Sendable {
    let sql: String
    let parameters: [Sendable?]
}

/// How a SwiftData entity maps to a PowerSync table, including SQL generation for the
/// operations the store performs.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
struct EntityMapping: @unchecked Sendable {
    let entityName: String
    let tableName: String
    /// The `@Model` property holding the PowerSync `id` column value.
    let idPropertyName: String
    /// All stored attribute mappings, excluding the id property.
    let properties: [PropertyMapping]
    /// To-one relationships, stored as foreign-key columns on this table.
    let toOne: [RelationshipMapping]
    /// To-many relationships, resolved through the destination's inverse column.
    let toMany: [ToManyMapping]

    /// O(1) lookups for the hot materialization and translation paths.
    let propertiesByName: [String: PropertyMapping]
    let toOneByName: [String: RelationshipMapping]
    let toManyByName: [String: ToManyMapping]

    init(
        entityName: String,
        tableName: String,
        idPropertyName: String,
        properties: [PropertyMapping],
        toOne: [RelationshipMapping],
        toMany: [ToManyMapping]
    ) {
        self.entityName = entityName
        self.tableName = tableName
        self.idPropertyName = idPropertyName
        self.properties = properties
        self.toOne = toOne
        self.toMany = toMany
        self.propertiesByName = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0) })
        self.toOneByName = Dictionary(uniqueKeysWithValues: toOne.map { ($0.name, $0) })
        self.toManyByName = Dictionary(uniqueKeysWithValues: toMany.map { ($0.name, $0) })
    }

    private static func quoted(_ name: String) -> String {
        sqlQuote(name)
    }

    func selectSQL(where whereClause: String?, orderBy: String?, limit: Int?, offset: Int?) -> String {
        var columns = [Self.quoted("id")]
        columns.append(contentsOf: properties.filter(\.isStored).map { Self.quoted($0.columnName) })
        columns.append(contentsOf: toOne.map { Self.quoted($0.columnName) })
        return assembleSQL(
            select: columns.joined(separator: ", "),
            where: whereClause,
            orderBy: orderBy,
            limit: limit,
            offset: offset
        )
    }

    func countSQL(where whereClause: String?) -> String {
        assembleSQL(select: "COUNT(*)", where: whereClause, orderBy: nil, limit: nil, offset: nil)
    }

    func identifiersSQL(where whereClause: String?, orderBy: String?, limit: Int?, offset: Int?) -> String {
        assembleSQL(
            select: Self.quoted("id"),
            where: whereClause,
            orderBy: orderBy,
            limit: limit,
            offset: offset
        )
    }

    private func assembleSQL(
        select: String,
        where whereClause: String?,
        orderBy: String?,
        limit: Int?,
        offset: Int?
    ) -> String {
        var sql = "SELECT \(select) FROM \(Self.quoted(tableName))"
        if let whereClause {
            sql += " WHERE \(whereClause)"
        }
        if let orderBy {
            sql += " ORDER BY \(orderBy)"
        }
        if let limit {
            sql += " LIMIT \(limit)"
            if let offset {
                sql += " OFFSET \(offset)"
            }
        } else if let offset {
            sql += " LIMIT -1 OFFSET \(offset)"
        }
        return sql
    }

    /// Reads one row into snapshot values keyed by property name. To-one foreign keys are
    /// read as raw id strings; ``PowerSyncSnapshot/init(row:entity:storeIdentifier:keyTransform:)``
    /// turns them into persistent identifiers. Reads everything inside the cursor mapper;
    /// the cursor must never escape this function.
    func row(from cursor: any SqlCursor) throws -> [String: any DataStoreSnapshotValue] {
        var row: [String: any DataStoreSnapshotValue] = [:]
        row[idPropertyName] = try cursor.getString(name: "id")
        for property in properties {
            let value = property.isStored
                ? try ValueCoercion.value(
                    from: cursor,
                    column: property.columnName,
                    kind: property.kind,
                    entity: entityName,
                    property: property.name
                )
                : nil
            if let value {
                row[property.name] = value
            } else if !property.isOptional {
                // Stored row predates the property (or sync delivered NULL). Materializing
                // a required property from nothing traps inside SwiftData, so fall back to
                // the declared default or fail with a descriptive error.
                guard
                    let defaultValue = property.defaultValue,
                    let value = ValueCoercion.snapshotValue(from: defaultValue, kind: property.kind)
                else {
                    throw PowerSyncSwiftDataError.missingRequiredValue(
                        entity: entityName,
                        property: property.name
                    )
                }
                row[property.name] = value
            }
        }
        for relationship in toOne {
            if let foreignKey = try cursor.getStringOptional(name: relationship.columnName) {
                row[relationship.name] = foreignKey
            }
        }
        return row
    }

    /// Converts a to-one snapshot value (a related identifier, or a raw id string) to a
    /// foreign-key parameter.
    private func foreignKeyParameter(
        _ value: (any DataStoreSnapshotValue)?,
        relationship: RelationshipMapping
    ) throws -> Sendable? {
        guard let value else { return nil }
        if let identifier = value as? PersistentIdentifier {
            return try PrimaryKeyResolver.primaryKey(of: identifier)
        }
        if let raw = value as? String {
            return raw
        }
        throw PowerSyncSwiftDataError.unsupportedValueType(
            entity: entityName,
            property: relationship.name,
            type: String(describing: type(of: value))
        )
    }

    func insertStatement(for snapshot: PowerSyncSnapshot, primaryKey: String) throws -> SQLStatement {
        var columns = [Self.quoted("id")]
        var parameters: [Sendable?] = [primaryKey]
        for property in properties where property.isStored {
            columns.append(Self.quoted(property.columnName))
            parameters.append(try ValueCoercion.parameter(
                from: snapshot.values[property.name],
                kind: property.kind,
                entity: entityName,
                property: property.name
            ))
        }
        for relationship in toOne {
            columns.append(Self.quoted(relationship.columnName))
            parameters.append(try foreignKeyParameter(snapshot.values[relationship.name], relationship: relationship))
        }
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        return SQLStatement(
            sql: "INSERT INTO \(Self.quoted(tableName)) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))",
            parameters: parameters
        )
    }

    /// Returns `nil` when the entity has no columns besides the id.
    func updateStatement(for snapshot: PowerSyncSnapshot, primaryKey: String) throws -> SQLStatement? {
        guard !properties.isEmpty || !toOne.isEmpty else { return nil }
        var assignments: [String] = []
        var parameters: [Sendable?] = []
        for property in properties where property.isStored {
            assignments.append("\(Self.quoted(property.columnName)) = ?")
            parameters.append(try ValueCoercion.parameter(
                from: snapshot.values[property.name],
                kind: property.kind,
                entity: entityName,
                property: property.name
            ))
        }
        for relationship in toOne {
            assignments.append("\(Self.quoted(relationship.columnName)) = ?")
            parameters.append(try foreignKeyParameter(snapshot.values[relationship.name], relationship: relationship))
        }
        parameters.append(primaryKey)
        return SQLStatement(
            sql: "UPDATE \(Self.quoted(tableName)) SET \(assignments.joined(separator: ", ")) WHERE \(Self.quoted("id")) = ?",
            parameters: parameters
        )
    }

    func deleteStatement(primaryKey: String) -> SQLStatement {
        SQLStatement(
            sql: "DELETE FROM \(Self.quoted(tableName)) WHERE \(Self.quoted("id")) = ?",
            parameters: [primaryKey]
        )
    }

    /// Stable description of the mapping used to detect conflicting registrations of the
    /// same entity name by different stores.
    var shapeSignature: String {
        let columns = properties
            .map { "\($0.name)=\($0.columnName):\($0.kind):\($0.isOptional):\($0.isStored)" }
            .sorted()
        let relationships = toOne.map { "\($0.name)->\($0.columnName)@\($0.destinationEntityName)" }.sorted()
        let inverses = toMany.map { "\($0.name)<-\($0.inverseColumnName)@\($0.destinationEntityName)" }.sorted()
        return "\(tableName)|\(columns)|\(relationships)|\(inverses)"
    }

    /// `SELECT id, fk FROM destination WHERE fk IN (...)` for batched to-many resolution.
    func childrenSQL(for toMany: ToManyMapping, parentCount: Int) -> String {
        let placeholders = Array(repeating: "?", count: parentCount).joined(separator: ", ")
        return "SELECT \(Self.quoted("id")), \(Self.quoted(toMany.inverseColumnName)) "
            + "FROM \(Self.quoted(toMany.destinationTableName)) "
            + "WHERE \(Self.quoted(toMany.inverseColumnName)) IN (\(placeholders))"
    }
}

/// Builds and caches the entity/property mapping for a SwiftData schema.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
struct SchemaMapper: Sendable {
    let entitiesByName: [String: EntityMapping]

    init(
        schema: SwiftData.Schema,
        tableNameForEntity: @Sendable (String) -> String,
        columnNameForProperty: @Sendable (String, String) -> String? = { _, _ in nil }
    ) throws {
        var result: [String: EntityMapping] = [:]
        var entitiesByTable: [String: String] = [:]
        for entity in schema.entities {
            guard entity.superentityName == nil, entity.subentities.isEmpty else {
                throw PowerSyncSwiftDataError.inheritanceUnsupported(entity: entity.name)
            }
            let tableName = tableNameForEntity(entity.name)
            if let existing = entitiesByTable[tableName] {
                throw PowerSyncSwiftDataError.tableCollision(table: tableName, entities: [existing, entity.name])
            }
            entitiesByTable[tableName] = entity.name
            let idPropertyName = "id"
            guard
                let idAttribute = entity.storedPropertiesByName[idPropertyName] as? SwiftData.Schema.Attribute,
                ValueCoercion.unwrapOptionalMetatype(idAttribute.valueType) == String.self
            else {
                throw PowerSyncSwiftDataError.modelRequiresStringId(entity: entity.name)
            }
            var properties: [PropertyMapping] = []
            var toOne: [RelationshipMapping] = []
            var toMany: [ToManyMapping] = []
            for property in entity.storedProperties {
                if property.name == idPropertyName {
                    continue
                }
                if let attribute = property as? SwiftData.Schema.Attribute {
                    if attribute.isTransformable {
                        throw PowerSyncSwiftDataError.unimplemented(
                            "transformable attributes (\(entity.name).\(property.name)); store a Codable value instead"
                        )
                    }
                    let kind = try ValueCoercion.kind(of: attribute.valueType, entity: entity.name, property: attribute.name)
                    // `Attribute.Option` is not Equatable, so `.ephemeral` is detected by
                    // description; the end-to-end ephemeral test guards this against SDK
                    // representation changes.
                    let isEphemeral = attribute.options.contains {
                        String(describing: $0).lowercased().contains("ephemeral")
                    }
                    properties.append(PropertyMapping(
                        name: attribute.name,
                        columnName: columnNameForProperty(entity.name, attribute.name) ?? attribute.name,
                        kind: kind,
                        isOptional: attribute.isOptional,
                        isStored: !attribute.isTransient && !isEphemeral,
                        defaultValue: attribute.defaultValue
                    ))
                    continue
                }
                guard let relationship = property as? SwiftData.Schema.Relationship else {
                    throw PowerSyncSwiftDataError.unsupportedValueType(
                        entity: entity.name,
                        property: property.name,
                        type: String(describing: type(of: property))
                    )
                }
                if relationship.isToOneRelationship {
                    guard let destinationType = ValueCoercion.unwrapOptionalMetatype(relationship.valueType)
                        as? any PersistentModel.Type
                    else {
                        throw PowerSyncSwiftDataError.unsupportedValueType(
                            entity: entity.name,
                            property: relationship.name,
                            type: String(describing: relationship.valueType)
                        )
                    }
                    toOne.append(RelationshipMapping(
                        name: relationship.name,
                        columnName: (columnNameForProperty(entity.name, relationship.name) ?? relationship.name) + "_id",
                        destinationEntityName: relationship.destination,
                        isOptional: relationship.isOptional,
                        keyPath: relationship.keypath,
                        destinationType: destinationType
                    ))
                } else {
                    // Resolved below, once every entity's to-one columns are known.
                    let elementType = Self.collectionElementType(relationship.valueType)
                    guard let elementType else {
                        throw PowerSyncSwiftDataError.unsupportedValueType(
                            entity: entity.name,
                            property: relationship.name,
                            type: String(describing: relationship.valueType)
                        )
                    }
                    toMany.append(ToManyMapping(
                        name: relationship.name,
                        destinationEntityName: relationship.destination,
                        destinationTableName: tableNameForEntity(relationship.destination),
                        inverseColumnName: "",
                        keyPath: relationship.keypath,
                        elementType: elementType
                    ))
                }
            }
            result[entity.name] = EntityMapping(
                entityName: entity.name,
                tableName: tableName,
                idPropertyName: idPropertyName,
                properties: properties,
                toOne: toOne,
                toMany: toMany
            )
        }

        // Second pass: resolve every to-many through the destination's inverse to-one
        // column. A to-many whose inverse is also to-many is a many-to-many without a join
        // model, which PowerSync cannot sync (the join table must exist as a synced table);
        // model the join explicitly as its own @Model with two to-one relationships.
        for (entityName, mapping) in result {
            guard !mapping.toMany.isEmpty else { continue }
            let resolved = try mapping.toMany.map { toMany -> ToManyMapping in
                guard let destination = result[toMany.destinationEntityName] else {
                    throw PowerSyncSwiftDataError.entityNotFound(toMany.destinationEntityName)
                }
                guard let inverse = destination.toOne.first(where: { $0.destinationEntityName == entityName }) else {
                    throw PowerSyncSwiftDataError.unimplemented(
                        "many-to-many between \(entityName) and \(toMany.destinationEntityName) without a join model. "
                            + "Declare an explicit join @Model with to-one relationships to both sides; "
                            + "PowerSync needs the join table as a synced table anyway."
                    )
                }
                return ToManyMapping(
                    name: toMany.name,
                    destinationEntityName: toMany.destinationEntityName,
                    destinationTableName: destination.tableName,
                    inverseColumnName: inverse.columnName,
                    keyPath: toMany.keyPath,
                    elementType: toMany.elementType
                )
            }
            result[entityName] = EntityMapping(
                entityName: mapping.entityName,
                tableName: mapping.tableName,
                idPropertyName: mapping.idPropertyName,
                properties: mapping.properties,
                toOne: mapping.toOne,
                toMany: resolved
            )
        }

        entitiesByName = result
    }

    private static func collectionElementType(_ valueType: Any.Type) -> (any PersistentModel.Type)? {
        guard let collection = ValueCoercion.unwrapOptionalMetatype(valueType) as? any RelationshipCollection.Type else {
            return nil
        }
        func open<C: RelationshipCollection>(_: C.Type) -> any PersistentModel.Type {
            C.PersistentElement.self
        }
        return open(collection)
    }

    func entity(named name: String) throws -> EntityMapping {
        guard let entity = entitiesByName[name] else {
            throw PowerSyncSwiftDataError.entityNotFound(name)
        }
        return entity
    }
}

/// Process-wide lookup from entity name to mapping, used where SwiftData hands us no store
/// reference: `PowerSyncSnapshot.init(from:relatedBackingDatas:)` and `Decodable`.
///
/// Stores register their mapper on creation. If two stores in one process map the same
/// entity name differently, the last registration wins; entity names are expected to be
/// unique per process.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
enum SnapshotEntityRegistry {
    private static let entities = Mutex<[String: EntityMapping]>([:])

    static func register(_ mapper: SchemaMapper) throws {
        try entities.withLock { storage in
            for (name, entity) in mapper.entitiesByName {
                if let existing = storage[name], existing.shapeSignature != entity.shapeSignature {
                    throw PowerSyncSwiftDataError.configurationConflict(entity: name)
                }
                storage[name] = entity
            }
        }
    }

    static func entity(named name: String) -> EntityMapping? {
        entities.withLock { $0[name] }
    }
}
