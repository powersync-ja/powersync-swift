import Foundation
import SwiftData

/// A generic `DataStoreSnapshot` backed by a dictionary of values keyed by *property name*.
///
/// SwiftData materializes models from snapshots by property name (validated by the phase 1
/// misaligned-name test), so the keys in ``values`` must mirror the `@Model` property names
/// exactly. Values are stored in their natural Swift types (`String`, `Bool`, `Int`, ...);
/// coercion to and from PowerSync's SQLite column types happens at the store boundary.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
public struct PowerSyncSnapshot: DataStoreSnapshot {
    public let persistentIdentifier: PersistentIdentifier

    /// The SwiftData entity name this snapshot belongs to.
    let entityName: String

    /// The PowerSync `id` column value, when known. Snapshots created from freshly inserted
    /// models carry a temporary identifier; ``PowerSyncDataStore/save(_:)`` mints the
    /// primary key (reusing the model's `id` property when set).
    let primaryKey: String?

    /// Property values keyed by `@Model` property name.
    let values: [String: any DataStoreSnapshotValue]

    init(
        persistentIdentifier: PersistentIdentifier,
        entityName: String,
        primaryKey: String?,
        values: [String: any DataStoreSnapshotValue]
    ) {
        self.persistentIdentifier = persistentIdentifier
        self.entityName = entityName
        self.primaryKey = primaryKey
        self.values = values
    }

    // MARK: model -> snapshot (invoked by SwiftData during save)

    public init(
        from backingData: any BackingData,
        relatedBackingDatas: inout [PersistentIdentifier: any BackingData]
    ) {
        guard let persistentIdentifier = backingData.persistentModelID else {
            preconditionFailure("BackingData has no persistent identifier")
        }
        self.persistentIdentifier = persistentIdentifier
        let entityName = persistentIdentifier.entityName
        self.entityName = entityName
        let entity = SnapshotEntityRegistry.entity(named: entityName)
        let values = Self.extractValues(from: backingData, entity: entity)
        self.values = values
        self.primaryKey = values[entity?.idPropertyName ?? "id"] as? String
        if let entity, values[entity.idPropertyName] == nil {
            // The id is a non-optional String every backing data carries; extracting
            // nothing means key-path resolution is broken. This initializer cannot throw,
            // so the failure is flagged for save() to surface.
            ReflectionHealth.flagExtractionFailure(entityName: entityName)
        }
    }

    /// Walks the model's stored properties and pulls each value out of the backing data.
    ///
    /// The `AnyKeyPath` from ``ModelPropertyReflection`` is dispatched against the two typed
    /// forms (`KeyPath<Model, V>` and `KeyPath<Model, V?>`) per value kind; `BackingData`
    /// only answers `getValue(forKey:)` for typed key paths.
    private static func extractValues(
        from backingData: any BackingData,
        entity: EntityMapping?
    ) -> [String: any DataStoreSnapshotValue] {
        func open<B: BackingData>(_ backingData: B) -> [String: any DataStoreSnapshotValue] {
            let idPropertyName = entity?.idPropertyName ?? "id"
            var values: [String: any DataStoreSnapshotValue] = [:]
            for property in ModelPropertyReflection.properties(for: B.Model.self) {
                let kind: ValueCoercion.Kind?
                if property.name == idPropertyName {
                    kind = .string
                } else {
                    kind = entity?.propertiesByName[property.name]?.kind
                }
                guard let kind else {
                    continue
                }
                func extract<V: Decodable & Encodable & Sendable>(_: V.Type) -> V? {
                    switch property.keyPath {
                    case let keyPath as KeyPath<B.Model, V>:
                        return backingData.getValue(forKey: keyPath)
                    case let keyPath as KeyPath<B.Model, V?>:
                        return backingData.getValue(forKey: keyPath)
                    default:
                        return nil
                    }
                }
                func extractAny(
                    _ type: any (Decodable & Encodable & Sendable).Type
                ) -> (any DataStoreSnapshotValue)? {
                    func go<V: Decodable & Encodable & Sendable>(_: V.Type) -> (any DataStoreSnapshotValue)? {
                        extract(V.self).map { $0 as any DataStoreSnapshotValue }
                    }
                    return go(type)
                }
                let value: (any DataStoreSnapshotValue)?
                switch kind {
                case .string: value = extract(String.self)
                case .bool: value = extract(Bool.self)
                case .int: value = extract(Int.self)
                case .int64: value = extract(Int64.self)
                case .int32: value = extract(Int32.self)
                case .double: value = extract(Double.self)
                case .float: value = extract(Float.self)
                case .date: value = extract(Date.self)
                case .uuid: value = extract(UUID.self)
                case .data: value = extract(Data.self)
                case let .rawRepresentable(type, _): value = extractAny(type)
                case let .codable(type): value = extractAny(type)
                }
                if let value {
                    values[property.name] = value
                }
            }
            if let entity {
                for relationship in entity.toOne {
                    let keyPath = relationship.keyPath
                        ?? ModelPropertyReflection.properties(for: B.Model.self)
                        .first(where: { $0.name == relationship.name })?.keyPath
                    guard let keyPath else { continue }
                    func related<R: PersistentModel>(_: R.Type) -> PersistentIdentifier? {
                        switch keyPath {
                        case let keyPath as KeyPath<B.Model, R>:
                            return backingData.getValue(forKey: keyPath).persistentModelID
                        case let keyPath as KeyPath<B.Model, R?>:
                            return backingData.getValue(forKey: keyPath)?.persistentModelID
                        default:
                            return nil
                        }
                    }
                    if let identifier = related(relationship.destinationType) {
                        values[relationship.name] = identifier
                    }
                }
                for relationship in entity.toMany {
                    let keyPath = relationship.keyPath
                        ?? ModelPropertyReflection.properties(for: B.Model.self)
                        .first(where: { $0.name == relationship.name })?.keyPath
                    guard let keyPath else { continue }
                    func related<R: PersistentModel>(_: R.Type) -> [PersistentIdentifier]? {
                        switch keyPath {
                        case let keyPath as KeyPath<B.Model, [R]>:
                            return backingData.getValue(forKey: keyPath).map(\.persistentModelID)
                        case let keyPath as KeyPath<B.Model, [R]?>:
                            return backingData.getValue(forKey: keyPath)?.map(\.persistentModelID)
                        default:
                            return nil
                        }
                    }
                    if let identifiers = related(relationship.elementType) {
                        values[relationship.name] = identifiers
                    }
                }
            }
            return values
        }
        return open(backingData)
    }

    // MARK: row -> snapshot (built by the store during fetch)

    init(
        row: [String: any DataStoreSnapshotValue],
        entity: EntityMapping,
        storeIdentifier: String,
        keyTransform: (@Sendable (String) -> String)?
    ) throws {
        guard let primaryKey = row[entity.idPropertyName] as? String else {
            throw PowerSyncSwiftDataError.missingPrimaryKey(entity: entity.entityName)
        }
        self.persistentIdentifier = try PrimaryKeyResolver.mint(
            store: storeIdentifier,
            entityName: entity.entityName,
            primaryKey: primaryKey
        )
        self.entityName = entity.entityName
        self.primaryKey = primaryKey
        var values = row
        // To-one columns arrive as raw id strings; turn them into identifiers of the
        // destination entity.
        for relationship in entity.toOne {
            if let foreignKey = values[relationship.name] as? String {
                values[relationship.name] = try PrimaryKeyResolver.mint(
                    store: storeIdentifier,
                    entityName: relationship.destinationEntityName,
                    primaryKey: foreignKey
                )
            }
        }
        if let keyTransform {
            self.values = Dictionary(uniqueKeysWithValues: values.map { (keyTransform($0.key), $0.value) })
        } else {
            self.values = values
        }
    }

    // MARK: copies

    public func copy(
        persistentIdentifier: PersistentIdentifier,
        remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]?
    ) -> PowerSyncSnapshot {
        // Attribute values are identifier-independent; relationship values (identifiers and
        // identifier arrays) are rewritten so references to models inserted in the same
        // save end up pointing at their permanent identifiers.
        var values = values
        if let remappedIdentifiers, !remappedIdentifiers.isEmpty {
            for (name, value) in values {
                if let identifier = value as? PersistentIdentifier {
                    if let remapped = remappedIdentifiers[identifier] {
                        values[name] = remapped
                    }
                } else if let identifiers = value as? [PersistentIdentifier] {
                    values[name] = identifiers.map { remappedIdentifiers[$0] ?? $0 }
                }
            }
        }
        return PowerSyncSnapshot(
            persistentIdentifier: persistentIdentifier,
            entityName: entityName,
            primaryKey: primaryKey,
            values: values
        )
    }

    /// Returns a copy carrying the minted primary key, both as ``primaryKey`` and as the
    /// model's id property value so the materialized model sees it.
    func settingPrimaryKey(_ primaryKey: String, idPropertyName: String) -> PowerSyncSnapshot {
        var values = values
        values[idPropertyName] = primaryKey
        return PowerSyncSnapshot(
            persistentIdentifier: persistentIdentifier,
            entityName: entityName,
            primaryKey: primaryKey,
            values: values
        )
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DataStoreSnapshotCodingKey.self)
        let persistentIdentifier = try container.decode(PersistentIdentifier.self, forKey: .persistentIdentifier)
        self.persistentIdentifier = persistentIdentifier
        let entityName = persistentIdentifier.entityName
        self.entityName = entityName
        let entity = SnapshotEntityRegistry.entity(named: entityName)
        let idPropertyName = entity?.idPropertyName ?? "id"
        var values: [String: any DataStoreSnapshotValue] = [:]
        for key in container.allKeys {
            guard case let .modeledProperty(name) = key else {
                continue
            }
            if let entity {
                if entity.toOneByName[name] != nil {
                    if let identifier = try container.decodeIfPresent(PersistentIdentifier.self, forKey: key) {
                        values[name] = identifier
                    }
                    continue
                }
                if entity.toManyByName[name] != nil {
                    if let identifiers = try container.decodeIfPresent([PersistentIdentifier].self, forKey: key) {
                        values[name] = identifiers
                    }
                    continue
                }
            }
            let kind: ValueCoercion.Kind?
            if name == idPropertyName {
                kind = .string
            } else {
                kind = entity?.propertiesByName[name]?.kind
            }
            if let value = try Self.decodeValue(kind, from: container, forKey: key) {
                values[name] = value
            }
        }
        self.values = values
        self.primaryKey = values[idPropertyName] as? String
    }

    private static func decodeValue(
        _ kind: ValueCoercion.Kind?,
        from container: KeyedDecodingContainer<DataStoreSnapshotCodingKey>,
        forKey key: DataStoreSnapshotCodingKey
    ) throws -> (any DataStoreSnapshotValue)? {
        func decodeAny(
            _ type: any (Decodable & Encodable & Sendable).Type
        ) throws -> (any DataStoreSnapshotValue)? {
            func go<V: Decodable & Encodable & Sendable>(_: V.Type) throws -> (any DataStoreSnapshotValue)? {
                try container.decodeIfPresent(V.self, forKey: key).map { $0 as any DataStoreSnapshotValue }
            }
            return try go(type)
        }

        switch kind {
        case .string: return try container.decodeIfPresent(String.self, forKey: key)
        case .bool: return try container.decodeIfPresent(Bool.self, forKey: key)
        case .int: return try container.decodeIfPresent(Int.self, forKey: key)
        case .int64: return try container.decodeIfPresent(Int64.self, forKey: key)
        case .int32: return try container.decodeIfPresent(Int32.self, forKey: key)
        case .double: return try container.decodeIfPresent(Double.self, forKey: key)
        case .float: return try container.decodeIfPresent(Float.self, forKey: key)
        case .date: return try container.decodeIfPresent(Date.self, forKey: key)
        case .uuid: return try container.decodeIfPresent(UUID.self, forKey: key)
        case .data: return try container.decodeIfPresent(Data.self, forKey: key)
        case let .rawRepresentable(type, _): return try decodeAny(type)
        case let .codable(type): return try decodeAny(type)
        case nil:
            // Unknown property (no registered entity): try the supported scalars in order.
            if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
            return nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DataStoreSnapshotCodingKey.self)
        try container.encode(persistentIdentifier, forKey: .persistentIdentifier)
        for (name, value) in values {
            try container.encode(value, forKey: .modeledProperty(name))
        }
        // SwiftData's model decoder looks every property up by name, so emit explicit nulls
        // for known properties with no value (optional attributes and to-one relationships
        // that are nil).
        if let entity = SnapshotEntityRegistry.entity(named: entityName) {
            for property in entity.properties where values[property.name] == nil {
                try container.encodeNil(forKey: .modeledProperty(property.name))
            }
            for relationship in entity.toOne where values[relationship.name] == nil {
                try container.encodeNil(forKey: .modeledProperty(relationship.name))
            }
            for relationship in entity.toMany where values[relationship.name] == nil {
                try container.encodeNil(forKey: .modeledProperty(relationship.name))
            }
        }
    }
}
