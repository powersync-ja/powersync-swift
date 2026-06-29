import Foundation
import PowerSync
import SwiftData

/// Re-injects PowerSync changes (sync downloads) into SwiftData so the UI updates live.
///
/// The observer watches each observed entity's PowerSync table. When rows change without
/// going through SwiftData (a sync download), it reconciles them into a private background
/// `ModelContext` whose `author` is the configuration's ``PowerSyncDataStoreConfiguration/remoteAuthor``
/// and saves. That save is echo-suppressed by ``PowerSyncDataStore/save(_:)`` (no write
/// goes back to PowerSync) but SwiftData still broadcasts `ModelContext.didSave`, which is
/// what `@Query` and other contexts react to.
///
/// Robustness:
/// - ``start(observing:)`` returns once every entity's initial state has been observed and
///   **throws** if any watch fails before that (a missing table must not hang the app).
/// - After priming, a failed watch stream is restarted with exponential backoff, so
///   transient errors cannot silently kill live updates.
/// - Emissions are coalesced per entity: if changes arrive faster than reconciliation, only
///   the latest table state is processed (no unbounded buffering of full-table emissions).
///
/// Local saves also wake the watcher (the table changed), but reconciliation diffs row
/// values against the registered models and finds nothing to change, and the echo-suppressed
/// save executes no SQL, so no loops can form.
///
/// The observer keeps the models of observed entities registered in its context to diff
/// incoming rows against the last known state. Memory cost is proportional to the number
/// of rows of the observed entities.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
public actor PowerSyncChangeObserver {
    private let container: ModelContainer
    private let configuration: PowerSyncDataStoreConfiguration
    private nonisolated let logger: any LoggerProtocol

    private struct PendingEmission {
        let type: any PersistentModel.Type
        let entity: EntityMapping
        let rows: [[String: any DataStoreSnapshotValue]]
    }

    private var watchTasks: [Task<Void, Never>] = []
    private var context: ModelContext?
    private var modelsByEntityAndId: [String: [String: any PersistentModel]] = [:]
    private var primedEntities: Set<String> = []
    private var primingErrors: [String: any Error] = [:]
    private var pendingEmissions: [String: PendingEmission] = [:]
    private var drainingEntities: Set<String> = []
    /// Incremented on every stop/reset; tasks from older generations become inert.
    private var generation = 0

    public init(container: ModelContainer, configuration: PowerSyncDataStoreConfiguration) {
        self.container = container
        self.configuration = configuration
        self.logger = configuration.database.logger
    }

    deinit {
        for task in watchTasks {
            task.cancel()
        }
    }

    /// Starts watching the PowerSync tables of the given model types. Returns once the
    /// initial state of every entity has been observed; throws if any watch fails before
    /// then, leaving the observer ready to be started again.
    public func start(observing types: [any PersistentModel.Type]) async throws {
        guard watchTasks.isEmpty else {
            return
        }
        guard let schema = configuration.schema else {
            throw PowerSyncSwiftDataError.missingSchema
        }
        let mapper: SchemaMapper
        do {
            mapper = try SchemaMapper(
                schema: schema,
                tableNameForEntity: configuration.tableNameForEntity,
                columnNameForProperty: configuration.columnNameForProperty
            )
        } catch {
            throw error
        }

        func entityName<M: PersistentModel>(of _: M.Type) -> String {
            SwiftData.Schema.entityName(for: M.self)
        }

        let currentGeneration = generation
        var entityNames: [String] = []
        do {
            for type in types {
                let name = entityName(of: type)
                entityNames.append(name)
                let entity = try mapper.entity(named: name)
                watchTasks.append(makeWatchTask(type: type, entity: entity, generation: currentGeneration))
            }
        } catch {
            cancelAndReset()
            throw error
        }

        // The first emission of each watch carries the current table state and primes the
        // registry; wait for all of them, surfacing the first failure instead of hanging.
        while true {
            if let failure = primingErrors.values.first {
                cancelAndReset()
                throw failure
            }
            if entityNames.allSatisfy({ primedEntities.contains($0) }) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Stops watching. The observer can be started again.
    public func stop() {
        cancelAndReset()
    }

    private func cancelAndReset() {
        generation += 1
        for task in watchTasks {
            task.cancel()
        }
        watchTasks = []
        primedEntities = []
        primingErrors = [:]
        pendingEmissions = [:]
        drainingEntities = []
        modelsByEntityAndId = [:]
        context = nil
    }

    // MARK: watching

    private func makeWatchTask(
        type: any PersistentModel.Type,
        entity: EntityMapping,
        generation: Int
    ) -> Task<Void, Never> {
        let database = configuration.database
        let sql = entity.selectSQL(where: nil, orderBy: nil, limit: nil, offset: nil)
        return Task { [weak self, logger] in
            var backoff: Duration = .milliseconds(250)
            while !Task.isCancelled {
                do {
                    let stream = try database.watch(sql: sql, parameters: []) { cursor in
                        try entity.row(from: cursor)
                    }
                    for try await rows in stream {
                        guard let self else { return }
                        await self.receive(rows: rows, type: type, entity: entity, generation: generation)
                        backoff = .milliseconds(250)
                    }
                    // The stream ended (database closed): nothing left to watch.
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    guard await self.noteWatchFailure(error, entityName: entity.entityName, generation: generation) else {
                        return
                    }
                    logger.error(
                        "watch for \(entity.tableName) failed; retrying in \(backoff): \(error)",
                        tag: "PowerSyncSwiftData"
                    )
                    try? await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, .seconds(30))
                }
            }
        }
    }

    /// Returns whether the watch task should retry. Failures before priming are stored for
    /// ``start(observing:)`` to throw; failures after priming are transient and retried.
    private func noteWatchFailure(_ error: any Error, entityName: String, generation: Int) -> Bool {
        guard generation == self.generation else {
            return false
        }
        if primedEntities.contains(entityName) {
            return true
        }
        primingErrors[entityName] = error
        return false
    }

    /// Stores the emission (replacing any unprocessed one for the entity) and kicks off a
    /// drain if none is running: bursts coalesce to the latest table state.
    private func receive(
        rows: [[String: any DataStoreSnapshotValue]],
        type: any PersistentModel.Type,
        entity: EntityMapping,
        generation: Int
    ) {
        guard generation == self.generation else {
            return
        }
        pendingEmissions[entity.entityName] = PendingEmission(type: type, entity: entity, rows: rows)
        guard !drainingEntities.contains(entity.entityName) else {
            return
        }
        drainingEntities.insert(entity.entityName)
        Task { [weak self] in
            await self?.drain(entityName: entity.entityName, generation: generation)
        }
    }

    private func drain(entityName: String, generation: Int) {
        defer { drainingEntities.remove(entityName) }
        while generation == self.generation, let emission = pendingEmissions.removeValue(forKey: entityName) {
            reconcile(emission)
        }
    }

    // MARK: reconciliation

    private nonisolated func logError(_ message: String) {
        logger.error(message, tag: "PowerSyncSwiftData")
    }

    private func ensureContext() -> ModelContext {
        if let context {
            return context
        }
        let created = ModelContext(container)
        created.author = configuration.remoteAuthor
        created.autosaveEnabled = false
        context = created
        return created
    }

    private func reconcile(_ emission: PendingEmission) {
        func open<M: PersistentModel>(_: M.Type) throws {
            try reconcileTyped(M.self, entity: emission.entity, rows: emission.rows)
        }
        do {
            try open(emission.type)
            primedEntities.insert(emission.entity.entityName)
        } catch {
            if primedEntities.contains(emission.entity.entityName) {
                logError("reconciliation for \(emission.entity.entityName) failed: \(error)")
            } else {
                // A failed priming must not mark the entity primed (a later emission would
                // diff against an empty registry and duplicate every row); it surfaces
                // through start() instead.
                primingErrors[emission.entity.entityName] = error
            }
        }
    }

    private func reconcileTyped<M: PersistentModel>(
        _: M.Type,
        entity: EntityMapping,
        rows: [[String: any DataStoreSnapshotValue]]
    ) throws {
        let context = ensureContext()
        let properties = ModelPropertyReflection.properties(for: M.self)
        var registry = modelsByEntityAndId[entity.entityName] ?? [:]
        defer { modelsByEntityAndId[entity.entityName] = registry }

        var rowsById: [String: [String: any DataStoreSnapshotValue]] = [:]
        for row in rows {
            if let id = row[entity.idPropertyName] as? String {
                rowsById[id] = row
            }
        }

        guard primedEntities.contains(entity.entityName) else {
            // First emission: register the current state without broadcasting anything.
            for model in try context.fetch(FetchDescriptor<M>()) {
                if let id = Self.idValue(of: model, entity: entity, properties: properties) {
                    registry[id] = model
                }
            }
            return
        }

        let knownIds = Set(registry.keys)
        let currentIds = Set(rowsById.keys)

        for id in knownIds.subtracting(currentIds) {
            if let model = registry.removeValue(forKey: id) as? M {
                context.delete(model)
            }
        }

        for id in currentIds.subtracting(knownIds) {
            guard let row = rowsById[id] else { continue }
            // Populate the backing data BEFORE creating the model: the @Model property
            // setters (and key-path writes) run the getter first, which traps on
            // uninitialized storage.
            var backingData: any BackingData<M> = M.createBackingData()
            Self.populate(&backingData, from: row, entity: entity, properties: properties)
            let model = M(backingData: backingData)
            context.insert(model)
            registry[id] = model
        }

        for id in currentIds.intersection(knownIds) {
            guard let model = registry[id] as? M, let row = rowsById[id] else { continue }
            Self.apply(row, to: model, entity: entity, properties: properties, diffing: true)
        }

        if context.hasChanges {
            try context.save()
        }
    }

    private static func idValue<M: PersistentModel>(
        of model: M,
        entity: EntityMapping,
        properties: [ModelPropertyReflection.Property]
    ) -> String? {
        guard let property = properties.first(where: { $0.name == entity.idPropertyName }) else {
            return nil
        }
        return model[keyPath: property.keyPath] as? String
    }

    private static func columnKind(
        of property: ModelPropertyReflection.Property,
        entity: EntityMapping
    ) -> ValueCoercion.Kind? {
        if property.name == entity.idPropertyName {
            return .string
        }
        return entity.propertiesByName[property.name]?.kind
    }

    /// Writes row values onto a registered model through its property setters (so SwiftData
    /// tracks the changes), skipping values whose column representation already matches.
    private static func apply<M: PersistentModel>(
        _ row: [String: any DataStoreSnapshotValue],
        to model: M,
        entity: EntityMapping,
        properties: [ModelPropertyReflection.Property],
        diffing: Bool
    ) {
        for property in properties {
            guard let kind = columnKind(of: property, entity: entity) else {
                continue
            }
            let newValue = row[property.name]
            if diffing {
                let currentValue = ValueCoercion.flattenOptional(model[keyPath: property.keyPath] as Any)
                if ValueCoercion.representationsEqual(currentValue, newValue, kind: kind) {
                    continue
                }
            }
            assign(newValue, to: model, keyPath: property.keyPath, kind: kind)
        }
    }

    /// Writes row values into fresh backing data (used before the model exists).
    private static func populate<B: BackingData>(
        _ backingData: inout B,
        from row: [String: any DataStoreSnapshotValue],
        entity: EntityMapping,
        properties: [ModelPropertyReflection.Property]
    ) {
        for property in properties {
            guard let kind = columnKind(of: property, entity: entity) else {
                continue
            }
            setBackingValue(row[property.name], on: &backingData, keyPath: property.keyPath, kind: kind)
        }
    }

    private static func setBackingValue<B: BackingData>(
        _ value: (any DataStoreSnapshotValue)?,
        on backingData: inout B,
        keyPath: AnyKeyPath,
        kind: ValueCoercion.Kind
    ) {
        func set<V: Decodable & Encodable & Sendable>(_: V.Type) {
            if let typed = keyPath as? KeyPath<B.Model, V> {
                if let concrete = value as? V {
                    backingData.setValue(forKey: typed, to: concrete)
                }
                return
            }
            if let typed = keyPath as? KeyPath<B.Model, V?> {
                backingData.setValue(forKey: typed, to: value as? V)
            }
        }
        func setAny(_ type: any (Decodable & Encodable & Sendable).Type) {
            func go<V: Decodable & Encodable & Sendable>(_: V.Type) {
                set(V.self)
            }
            go(type)
        }
        switch kind {
        case .string: set(String.self)
        case .bool: set(Bool.self)
        case .int: set(Int.self)
        case .int64: set(Int64.self)
        case .int32: set(Int32.self)
        case .double: set(Double.self)
        case .float: set(Float.self)
        case .date: set(Date.self)
        case .uuid: set(UUID.self)
        case .data: set(Data.self)
        case let .rawRepresentable(type, _): setAny(type)
        case let .codable(type): setAny(type)
        }
    }

    private static func assign<M: PersistentModel>(
        _ value: (any DataStoreSnapshotValue)?,
        to model: M,
        keyPath: AnyKeyPath,
        kind: ValueCoercion.Kind
    ) {
        func set<V>(_: V.Type) {
            if let writable = keyPath as? ReferenceWritableKeyPath<M, V> {
                if let typed = value as? V {
                    model[keyPath: writable] = typed
                }
                return
            }
            if let writable = keyPath as? ReferenceWritableKeyPath<M, V?> {
                model[keyPath: writable] = value as? V
            }
        }
        func setAny(_ type: any (Decodable & Encodable & Sendable).Type) {
            func go<V: Decodable & Encodable & Sendable>(_: V.Type) {
                set(V.self)
            }
            go(type)
        }
        switch kind {
        case .string: set(String.self)
        case .bool: set(Bool.self)
        case .int: set(Int.self)
        case .int64: set(Int64.self)
        case .int32: set(Int32.self)
        case .double: set(Double.self)
        case .float: set(Float.self)
        case .date: set(Date.self)
        case .uuid: set(UUID.self)
        case .data: set(Data.self)
        case let .rawRepresentable(type, _): setAny(type)
        case let .codable(type): setAny(type)
        }
    }
}
