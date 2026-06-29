import Foundation
import PowerSync
import SwiftData
import Synchronization

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

/// A SwiftData `DataStore` backed by a PowerSync database.
///
/// SwiftData operations (`@Query`, `ModelContext.fetch`, `ModelContext.save`) are translated
/// to PowerSync queries and writes. Writes go through PowerSync views, so they are captured
/// in the `ps_crud` upload queue and synchronized by the app's backend connector. PowerSync
/// owns the only SQLite connection; the store never opens a second one.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
public final class PowerSyncDataStore: DataStore, DataStoreBatching {
    public typealias Configuration = PowerSyncDataStoreConfiguration
    public typealias Snapshot = PowerSyncSnapshot

    public let configuration: PowerSyncDataStoreConfiguration
    public let identifier: String

    let database: any PowerSyncDatabaseProtocol
    private let cachedMapper = Mutex<SchemaMapper?>(nil)
    /// Per-entity translators (their key-path tables are built once, not per fetch).
    private let translators = Mutex<[String: PredicateTranslator]>([:])
    /// Model types whose key-path coverage has been validated against the mapping.
    private let validatedModels = Mutex<Set<ObjectIdentifier>>([])

    public var schema: SwiftData.Schema {
        configuration.schema ?? SwiftData.Schema()
    }

    public init(
        _ configuration: PowerSyncDataStoreConfiguration,
        migrationPlan: (any SchemaMigrationPlan.Type)?
    ) throws {
        guard migrationPlan == nil else {
            throw PowerSyncSwiftDataError.migrationPlansUnsupported
        }
        self.configuration = configuration
        self.identifier = configuration.name
        self.database = configuration.database
        if configuration.schema != nil {
            _ = try mapper()
        }
        // Self-check the identifier's private Codable envelope once per store. With the
        // mint cache in front it is only a fallback, but drift deserves a loud signal.
        if let probe = try? PersistentIdentifier.identifier(
            for: identifier,
            entityName: "_powersync_probe",
            primaryKey: "probe"
        ), (try? probe.powerSyncPrimaryKey()) != "probe" {
            configuration.database.logger.error(
                "PersistentIdentifier's Codable envelope changed in this SDK; identifier "
                    + "resolution now relies on the in-process mint cache only. "
                    + "Report this to powersync-swift.",
                tag: "PowerSyncSwiftData"
            )
        }
    }

    /// `ModelContainer` injects the schema into the configuration, so the mapper is built on
    /// first use and cached. Building it also registers the entity mappings for
    /// ``PowerSyncSnapshot`` initializers that receive no store reference.
    private func mapper() throws -> SchemaMapper {
        if let mapper = cachedMapper.withLock({ $0 }) {
            return mapper
        }
        guard let schema = configuration.schema else {
            throw PowerSyncSwiftDataError.missingSchema
        }
        let mapper = try SchemaMapper(
            schema: schema,
            tableNameForEntity: configuration.tableNameForEntity,
            columnNameForProperty: configuration.columnNameForProperty
        )
        try validateMapping(mapper)
        try SnapshotEntityRegistry.register(mapper)
        return cachedMapper.withLock { storage in
            if let existing = storage {
                return existing
            }
            storage = mapper
            return mapper
        }
    }

    /// Verifies every mapped table and column against the actual database, so mapping
    /// mistakes fail container creation with a precise error instead of surfacing as
    /// cryptic SQL failures (or observer hangs) on first use.
    private func validateMapping(_ mapper: SchemaMapper) throws {
        let database = self.database
        for entity in mapper.entitiesByName.values {
            let table = entity.tableName
            let existingColumns = try AsyncBridge.blocking {
                try await database.getAll(
                    sql: "SELECT name FROM pragma_table_xinfo(?)",
                    parameters: [table]
                ) { try $0.getString(name: "name") }
            }
            guard !existingColumns.isEmpty else {
                throw PowerSyncSwiftDataError.tableMissing(entity: entity.entityName, table: table)
            }
            let required = ["id"]
                + entity.properties.filter(\.isStored).map(\.columnName)
                + entity.toOne.map(\.columnName)
            let missing = required.filter { !existingColumns.contains($0) }
            guard missing.isEmpty else {
                throw PowerSyncSwiftDataError.columnsMissing(
                    entity: entity.entityName,
                    table: table,
                    columns: missing
                )
            }
        }
    }

    /// Translates the descriptor's predicate and sort. Untranslatable nodes surface as
    /// `DataStoreError.preferInMemoryFilter`/`.preferInMemorySort`, telling SwiftData to
    /// filter or sort in memory.
    private func translate<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        entity: EntityMapping
    ) throws -> (whereClause: String?, bindings: [Sendable?], orderBy: String?) {
        let translator = translators.withLock { cache -> PredicateTranslator in
            if let cached = cache[entity.entityName] {
                return cached
            }
            let created = PredicateTranslator(entity: entity, modelType: T.self)
            cache[entity.entityName] = created
            return created
        }
        var whereClause: String?
        var bindings: [Sendable?] = []
        if let predicate = descriptor.predicate {
            let translated = try translator.translateWhere(predicate)
            whereClause = translated.clause
            bindings = translated.bindings
        }
        let orderBy = try translator.translateOrderBy(descriptor.sortBy)
        return (whereClause, bindings, orderBy)
    }

    /// One-time (per model type) runtime check that key-path resolution covers every
    /// mapped attribute, so SDK drift fails the first fetch descriptively.
    private func ensureReflectionCoverage<T: PersistentModel>(_: T.Type, entity: EntityMapping) throws {
        let key = ObjectIdentifier(T.self)
        let alreadyValidated = validatedModels.withLock { $0.contains(key) }
        guard !alreadyValidated else { return }
        try ModelPropertyReflection.validateCoverage(of: T.self, entity: entity)
        validatedModels.withLock { _ = $0.insert(key) }
    }

    public func fetch<T: PersistentModel>(
        _ request: DataStoreFetchRequest<T>
    ) throws -> DataStoreFetchResult<T, PowerSyncSnapshot> {
        let descriptor = request.descriptor
        let entity = try mapper().entity(named: SwiftData.Schema.entityName(for: T.self))
        try ensureReflectionCoverage(T.self, entity: entity)
        let (whereClause, bindings, orderBy) = try translate(descriptor, entity: entity)
        let sql = entity.selectSQL(
            where: whereClause,
            orderBy: orderBy,
            limit: descriptor.fetchLimit,
            offset: descriptor.fetchOffset
        )
        let database = self.database
        var rows = try AsyncBridge.blocking {
            try await database.getAll(sql: sql, parameters: bindings) { cursor in
                // Everything is read inside the mapper; the cursor never escapes.
                try entity.row(from: cursor)
            }
        }
        try populateToMany(entity: entity, rows: &rows)
        let storeIdentifier = identifier
        let keyTransform = configuration._testFetchKeyTransform
        let snapshots = try rows.map { row in
            try PowerSyncSnapshot(
                row: row,
                entity: entity,
                storeIdentifier: storeIdentifier,
                keyTransform: keyTransform
            )
        }
        return DataStoreFetchResult(
            descriptor: descriptor,
            fetchedSnapshots: snapshots,
            relatedSnapshots: [:]
        )
    }

    /// Resolves the entity's to-many relationships for the fetched rows with one batched
    /// query per relationship over the destination's inverse foreign-key column.
    private func populateToMany(
        entity: EntityMapping,
        rows: inout [[String: any DataStoreSnapshotValue]]
    ) throws {
        guard !entity.toMany.isEmpty, !rows.isEmpty else {
            return
        }
        let parentIds = rows.compactMap { $0[entity.idPropertyName] as? String }
        let database = self.database
        let storeIdentifier = identifier
        for relationship in entity.toMany {
            var childrenByParent: [String: [PersistentIdentifier]] = [:]
            for chunk in parentIds.chunked(into: 500) {
                let sql = entity.childrenSQL(for: relationship, parentCount: chunk.count)
                let inverseColumn = relationship.inverseColumnName
                let pairs = try AsyncBridge.blocking {
                    try await database.getAll(sql: sql, parameters: chunk) { cursor in
                        (try cursor.getString(name: "id"), try cursor.getString(name: inverseColumn))
                    }
                }
                for (childId, parentId) in pairs {
                    let identifier = try PrimaryKeyResolver.mint(
                        store: storeIdentifier,
                        entityName: relationship.destinationEntityName,
                        primaryKey: childId
                    )
                    childrenByParent[parentId, default: []].append(identifier)
                }
            }
            for index in rows.indices {
                guard let parentId = rows[index][entity.idPropertyName] as? String else { continue }
                rows[index][relationship.name] = childrenByParent[parentId] ?? []
            }
        }
    }

    /// Deletes every row matching the request's predicate with a single SQL DELETE,
    /// captured by PowerSync's triggers for upload.
    public func delete<T: PersistentModel>(
        _ request: DataStoreBatchDeleteRequest<T>
    ) throws {
        guard !configuration.readOnly else {
            throw DataStoreError.unsupportedFeature
        }
        guard request.editingState.author != configuration.remoteAuthor else {
            return
        }
        let entity = try mapper().entity(named: SwiftData.Schema.entityName(for: T.self))
        var whereClause: String?
        var bindings: [Sendable?] = []
        if let predicate = request.predicate {
            let translator = PredicateTranslator(entity: entity, modelType: T.self)
            let translated = try translator.translateWhere(predicate)
            whereClause = translated.clause
            bindings = translated.bindings
        }
        var sql = "DELETE FROM \(sqlQuote(entity.tableName))"
        if let whereClause {
            sql += " WHERE \(whereClause)"
        }
        let database = self.database
        let statement = SQLStatement(sql: sql, parameters: bindings)
        try AsyncBridge.blocking {
            try await database.writeTransaction { transaction in
                _ = try transaction.execute(sql: statement.sql, parameters: statement.parameters)
            }
        }
    }

    /// Erasing the store is intentionally unsupported. Resetting local PowerSync data is
    /// `PowerSyncDatabaseProtocol.disconnectAndClear()`'s job; routing it through the
    /// store would capture a DELETE for every row into the upload queue and destroy
    /// server-side data.
    public func erase() throws {
        throw DataStoreError.unsupportedFeature
    }

    /// Returns fresh snapshots for the requested identifiers, straight from the database.
    /// SwiftData uses this to restore model state, e.g. on `ModelContext.rollback()`.
    public func cachedSnapshots(
        for persistentIdentifiers: [PersistentIdentifier],
        editingState: EditingState
    ) throws -> [PersistentIdentifier: PowerSyncSnapshot] {
        let mapper = try mapper()
        let database = self.database
        let storeIdentifier = identifier
        var snapshots: [PersistentIdentifier: PowerSyncSnapshot] = [:]
        let byEntity = Dictionary(grouping: persistentIdentifiers, by: \.entityName)
        for (entityName, identifiers) in byEntity {
            let entity = try mapper.entity(named: entityName)
            let primaryKeys = try identifiers.map { try PrimaryKeyResolver.primaryKey(of: $0) }
            for chunk in primaryKeys.chunked(into: 500) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let sql = entity.selectSQL(
                    where: "\(sqlQuote("id")) IN (\(placeholders))",
                    orderBy: nil,
                    limit: nil,
                    offset: nil
                )
                var rows = try AsyncBridge.blocking {
                    try await database.getAll(sql: sql, parameters: chunk) { cursor in
                        try entity.row(from: cursor)
                    }
                }
                try populateToMany(entity: entity, rows: &rows)
                for row in rows {
                    let snapshot = try PowerSyncSnapshot(
                        row: row,
                        entity: entity,
                        storeIdentifier: storeIdentifier,
                        keyTransform: nil
                    )
                    snapshots[snapshot.persistentIdentifier] = snapshot
                }
            }
        }
        return snapshots
    }

    public func fetchCount<T: PersistentModel>(
        _ request: DataStoreFetchRequest<T>
    ) throws -> Int {
        let descriptor = request.descriptor
        let entity = try mapper().entity(named: SwiftData.Schema.entityName(for: T.self))
        let (whereClause, bindings, _) = try translate(descriptor, entity: entity)
        let sql = entity.countSQL(where: whereClause)
        let database = self.database
        var count = try AsyncBridge.blocking {
            try await database.get(sql: sql, parameters: bindings) { cursor in
                try cursor.getInt(index: 0)
            }
        }
        // Count what the fetch would return: discount the offset, then cap at the limit.
        if let offset = descriptor.fetchOffset {
            count = max(0, count - offset)
        }
        if let limit = descriptor.fetchLimit {
            count = min(count, limit)
        }
        return count
    }

    public func fetchIdentifiers<T: PersistentModel>(
        _ request: DataStoreFetchRequest<T>
    ) throws -> [PersistentIdentifier] {
        let descriptor = request.descriptor
        let entityName = SwiftData.Schema.entityName(for: T.self)
        let entity = try mapper().entity(named: entityName)
        let (whereClause, bindings, orderBy) = try translate(descriptor, entity: entity)
        let sql = entity.identifiersSQL(
            where: whereClause,
            orderBy: orderBy,
            limit: descriptor.fetchLimit,
            offset: descriptor.fetchOffset
        )
        let database = self.database
        let primaryKeys = try AsyncBridge.blocking {
            try await database.getAll(sql: sql, parameters: bindings) { cursor in
                try cursor.getString(name: "id")
            }
        }
        let storeIdentifier = identifier
        return try primaryKeys.map { primaryKey in
            try PrimaryKeyResolver.mint(
                store: storeIdentifier,
                entityName: entityName,
                primaryKey: primaryKey
            )
        }
    }

    public func save(
        _ request: DataStoreSaveChangesRequest<PowerSyncSnapshot>
    ) throws -> DataStoreSaveChangesResult<PowerSyncSnapshot> {
        guard !configuration.readOnly else {
            throw DataStoreError.unsupportedFeature
        }
        let mapper = try mapper()

        // Echo suppression: saves authored by the change observer re-inject data that came
        // FROM PowerSync, so nothing is written back. Inserted snapshots still need their
        // permanent identifiers minted so SwiftData can register the models.
        if request.editingState.author == configuration.remoteAuthor {
            var remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier] = [:]
            var snapshotsToReregister: [PersistentIdentifier: PowerSyncSnapshot] = [:]
            for snapshot in request.inserted {
                let entity = try mapper.entity(named: snapshot.entityName)
                guard let primaryKey = snapshot.primaryKey ?? (snapshot.values[entity.idPropertyName] as? String),
                      !primaryKey.isEmpty
                else {
                    throw PowerSyncSwiftDataError.missingPrimaryKey(entity: snapshot.entityName)
                }
                let permanentIdentifier = try PrimaryKeyResolver.mint(
                    store: identifier,
                    entityName: snapshot.entityName,
                    primaryKey: primaryKey
                )
                remappedIdentifiers[snapshot.persistentIdentifier] = permanentIdentifier
                snapshotsToReregister[permanentIdentifier] = snapshot
                    .settingPrimaryKey(primaryKey, idPropertyName: entity.idPropertyName)
                    .copy(persistentIdentifier: permanentIdentifier, remappedIdentifiers: nil)
            }
            return DataStoreSaveChangesResult(
                for: identifier,
                remappedIdentifiers: remappedIdentifiers,
                snapshotsToReregister: snapshotsToReregister
            )
        }

        var remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier] = [:]
        var snapshotsToReregister: [PersistentIdentifier: PowerSyncSnapshot] = [:]
        var insertStatements: [SQLStatement] = []
        var updateStatements: [SQLStatement] = []
        var deleteStatements: [SQLStatement] = []

        // First pass: mint a permanent identifier for every inserted snapshot. Snapshots
        // may reference each other (a child inserted together with its parent, including
        // cycles), so the full map must exist before any statement is built. PowerSync
        // tables are views over JSON without enforced foreign keys, so insert order never
        // matters.
        var insertedKeys: [(snapshot: PowerSyncSnapshot, entity: EntityMapping, primaryKey: String)] = []
        for snapshot in request.inserted {
            try ReflectionHealth.assertHealthy(entityName: snapshot.entityName)
            let entity = try mapper.entity(named: snapshot.entityName)
            let modelId = snapshot.primaryKey ?? (snapshot.values[entity.idPropertyName] as? String)
            let primaryKey: String
            if let modelId, !modelId.isEmpty {
                primaryKey = modelId
            } else {
                primaryKey = UUID().uuidString.lowercased()
            }
            let permanentIdentifier = try PrimaryKeyResolver.mint(
                store: identifier,
                entityName: snapshot.entityName,
                primaryKey: primaryKey
            )
            remappedIdentifiers[snapshot.persistentIdentifier] = permanentIdentifier
            insertedKeys.append((snapshot, entity, primaryKey))
        }

        // Second pass: build statements with relationship references rewritten through the
        // complete remapping.
        for (snapshot, entity, primaryKey) in insertedKeys {
            let permanentIdentifier = remappedIdentifiers[snapshot.persistentIdentifier]!
            let saved = snapshot
                .settingPrimaryKey(primaryKey, idPropertyName: entity.idPropertyName)
                .copy(persistentIdentifier: permanentIdentifier, remappedIdentifiers: remappedIdentifiers)
            insertStatements.append(try entity.insertStatement(for: saved, primaryKey: primaryKey))
            snapshotsToReregister[permanentIdentifier] = saved
        }

        for snapshot in request.updated {
            let entity = try mapper.entity(named: snapshot.entityName)
            // The row is addressed by the identifier SwiftData registered, never by the id
            // property: a mutated id would silently target nothing.
            let primaryKey = try PrimaryKeyResolver.primaryKey(of: snapshot.persistentIdentifier)
            if let modelId = snapshot.values[entity.idPropertyName] as? String, modelId != primaryKey {
                throw PowerSyncSwiftDataError.idMutationUnsupported(entity: snapshot.entityName)
            }
            // Updated snapshots can reference models inserted in this same save.
            let resolved = snapshot.copy(
                persistentIdentifier: snapshot.persistentIdentifier,
                remappedIdentifiers: remappedIdentifiers
            )
            if let statement = try entity.updateStatement(for: resolved, primaryKey: primaryKey) {
                updateStatements.append(statement)
            }
        }

        for snapshot in request.deleted {
            let entity = try mapper.entity(named: snapshot.entityName)
            // Deletes also address the registered identifier (a mutated id must not stop
            // the row from being removed).
            let primaryKey = try PrimaryKeyResolver.primaryKey(of: snapshot.persistentIdentifier)
            deleteStatements.append(entity.deleteStatement(primaryKey: primaryKey))
        }

        // Deletes run first so a delete+insert pair sharing an id (the "replace" pattern)
        // does not trip the primary key constraint; inserted rows are never deleted by the
        // same request because SwiftData never reports a snapshot as both.
        let statements = deleteStatements + insertStatements + updateStatements

        if !statements.isEmpty {
            let database = self.database
            let pending = statements
            // One write transaction per save request: the batch is atomic, and PowerSync's
            // triggers capture every statement into the ps_crud upload queue.
            try AsyncBridge.blocking {
                try await database.writeTransaction { transaction in
                    for statement in pending {
                        _ = try transaction.execute(sql: statement.sql, parameters: statement.parameters)
                    }
                }
            }
        }

        return DataStoreSaveChangesResult(
            for: identifier,
            remappedIdentifiers: remappedIdentifiers,
            snapshotsToReregister: snapshotsToReregister
        )
    }
}
