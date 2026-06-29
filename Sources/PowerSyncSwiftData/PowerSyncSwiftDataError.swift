/// Errors thrown by the PowerSync SwiftData integration.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
public enum PowerSyncSwiftDataError: Error, CustomStringConvertible {
    /// The requested functionality has not been implemented yet.
    case unimplemented(String)
    /// No entity with the given name exists in the SwiftData schema handed to the store.
    case entityNotFound(String)
    /// The store configuration is missing a SwiftData schema.
    ///
    /// `ModelContainer` injects the schema into the configuration before creating the store.
    /// This error indicates the configuration was used outside of a `ModelContainer`.
    case missingSchema
    /// A model property uses a value type that cannot be stored in a PowerSync column.
    case unsupportedValueType(entity: String, property: String, type: String)
    /// A snapshot did not contain the value required to derive the PowerSync `id` column.
    case missingPrimaryKey(entity: String)
    /// Synchronized models must expose a `String` property mapped to PowerSync's `id` column.
    case modelRequiresStringId(entity: String)
    /// A stored row has no value for a required property and the property declares no
    /// default. Typically the row predates the property; give the property a default value.
    case missingRequiredValue(entity: String, property: String)
    /// SwiftData `SchemaMigrationPlan`s are not supported: schema evolution is driven by
    /// the backend and PowerSync's views (see the module README's schema evolution notes).
    case migrationPlansUnsupported
    /// The id property of a saved model was mutated. Rows are addressed by their persistent
    /// identifier; to change a row's id, delete the model and insert a new one.
    case idMutationUnsupported(entity: String)
    /// A stored integer does not fit the model property's integer type.
    case valueOutOfRange(entity: String, property: String)
    /// The PowerSync database has no table (view) for a mapped entity.
    case tableMissing(entity: String, table: String)
    /// The entity's table exists but lacks mapped columns.
    case columnsMissing(entity: String, table: String, columns: [String])
    /// Two entities map to the same PowerSync table.
    case tableCollision(table: String, entities: [String])
    /// Two stores in this process registered the same entity with different mappings.
    case configurationConflict(entity: String)
    /// Model inheritance hierarchies are not supported.
    case inheritanceUnsupported(entity: String)
    /// A private SwiftData surface the integration relies on changed shape in this SDK.
    case sdkDriftDetected(detail: String)

    public var description: String {
        switch self {
        case let .unimplemented(what):
            return "Not implemented: \(what)"
        case let .entityNotFound(name):
            return "Entity \(name) was not found in the SwiftData schema"
        case .missingSchema:
            return "The configuration has no SwiftData schema. Use it through a ModelContainer."
        case let .unsupportedValueType(entity, property, type):
            return "Unsupported value type \(type) for \(entity).\(property)"
        case let .missingPrimaryKey(entity):
            return "Snapshot for \(entity) is missing a primary key value"
        case let .modelRequiresStringId(entity):
            return "\(entity) must declare a String `id` property mapped to PowerSync's id column"
        case let .missingRequiredValue(entity, property):
            return "A stored \(entity) row has no value for required property \(property); "
                + "declare a default value for properties added after rows existed"
        case .migrationPlansUnsupported:
            return "SchemaMigrationPlans are not supported; schema evolution is backend-driven "
                + "(see the PowerSyncSwiftData README)"
        case let .idMutationUnsupported(entity):
            return "The id of a saved \(entity) cannot change; delete the model and insert a new one"
        case let .valueOutOfRange(entity, property):
            return "A stored value for \(entity).\(property) does not fit the property's integer type"
        case let .tableMissing(entity, table):
            return "The PowerSync database has no table \(table) for entity \(entity); "
                + "declare it in the PowerSync schema (PowerSyncSchema(for:) derives it)"
        case let .columnsMissing(entity, table, columns):
            return "Table \(table) for entity \(entity) lacks columns: \(columns.joined(separator: ", "))"
        case let .tableCollision(table, entities):
            return "Entities \(entities.joined(separator: ", ")) map to the same table \(table)"
        case let .configurationConflict(entity):
            return "Entity \(entity) is already registered by another store with a different mapping; "
                + "entity names must map consistently within a process"
        case let .inheritanceUnsupported(entity):
            return "\(entity) uses model inheritance, which is not supported; flatten the hierarchy"
        case let .sdkDriftDetected(detail):
            return "SwiftData SDK drift detected: \(detail)"
        }
    }
}
