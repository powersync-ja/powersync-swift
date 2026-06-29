import Foundation
import SwiftData

/// Translates `FetchDescriptor` predicates and sort descriptors to PowerSync SQL.
///
/// Translation is structural: only expression nodes the translator understands (the
/// retroactive ``SQLTranslatableExpression`` conformances below) produce SQL; any other
/// node makes the whole predicate untranslatable and SwiftData is asked to filter or sort
/// in memory via `DataStoreError.preferInMemoryFilter`/`.preferInMemorySort`.
///
/// Known semantic approximations (documented in the module README):
/// - String sorts use `COLLATE NOCASE` (ASCII case-insensitive), an approximation of
///   `SortDescriptor`'s default localized-standard comparator.
/// - `starts(with:)`/`contains` translate to `LIKE`, which is ASCII case-insensitive in
///   SQLite, whereas the Swift operators are case-sensitive. Locale-aware operators such as
///   `localizedStandardContains` are NOT translated and fall back to in-memory filtering.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
struct PredicateTranslator: @unchecked Sendable {
    let entity: EntityMapping
    let modelType: any PersistentModel.Type
    /// Computed once: key-path resolution is on the hot path of every fetch.
    private let columns: [AnyKeyPath: SQLColumnReference]

    init(entity: EntityMapping, modelType: any PersistentModel.Type) {
        self.entity = entity
        self.modelType = modelType
        self.columns = Self.columnsByKeyPath(entity: entity, modelType: modelType)
    }

    /// Returns the SQL boolean clause (without the `WHERE` keyword) and its bindings.
    /// - Throws: `DataStoreError.preferInMemoryFilter` for unsupported expression nodes.
    func translateWhere<T>(_ predicate: Predicate<T>) throws -> (clause: String, bindings: [Sendable?]) {
        let context = SQLTranslationContext(entity: entity, columnsByKeyPath: columns)
        guard let expression = predicate.expression as? any SQLTranslatableExpression else {
            throw DataStoreError.preferInMemoryFilter
        }
        let fragment = try expression.sqlFragment(in: context)
        let (clause, bindings, _) = try fragment.booleanClause()
        return (clause, bindings)
    }

    /// Returns the `ORDER BY` body (without the keywords), or `nil` when there is nothing
    /// to sort by.
    /// - Throws: `DataStoreError.preferInMemorySort` for unsupported sort descriptors.
    func translateOrderBy<T>(_ sortBy: [SortDescriptor<T>]) throws -> String? {
        guard !sortBy.isEmpty else {
            return nil
        }
        var terms: [String] = []
        for descriptor in sortBy {
            guard let keyPath = descriptor.keyPath, let column = columns[keyPath] else {
                throw DataStoreError.preferInMemorySort
            }
            var term = sqlQuote(column.column)
            if case .string = column.kind {
                term += " COLLATE NOCASE"
            }
            term += descriptor.order == .forward ? " ASC" : " DESC"
            terms.append(term)
        }
        return terms.joined(separator: ", ")
    }

    static func columnsByKeyPath(
        entity: EntityMapping,
        modelType: any PersistentModel.Type
    ) -> [AnyKeyPath: SQLColumnReference] {
        var columns: [AnyKeyPath: SQLColumnReference] = [:]
        for property in ModelPropertyReflection.properties(for: modelType) {
            if property.name == entity.idPropertyName {
                columns[property.keyPath] = SQLColumnReference(column: "id", kind: .string, isOptional: false)
            } else if let mapping = entity.propertiesByName[property.name] {
                columns[property.keyPath] = SQLColumnReference(
                    column: mapping.columnName,
                    kind: mapping.kind,
                    isOptional: mapping.isOptional
                )
            } else if let relationship = entity.toOneByName[property.name] {
                // Comparisons against the relationship bind the related row's id.
                columns[property.keyPath] = SQLColumnReference(
                    column: relationship.columnName,
                    kind: .string,
                    isOptional: relationship.isOptional,
                    relationship: relationship
                )
            }
        }
        for relationship in entity.toOne {
            if let keyPath = relationship.keyPath {
                columns[keyPath] = SQLColumnReference(
                    column: relationship.columnName,
                    kind: .string,
                    isOptional: relationship.isOptional,
                    relationship: relationship
                )
            }
        }
        func addPersistentModelID<M: PersistentModel>(_: M.Type) {
            columns[\M.persistentModelID] = SQLColumnReference(column: "id", kind: .string, isOptional: false)
        }
        addPersistentModelID(modelType)
        return columns
    }
}

// MARK: - Translation machinery

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
struct SQLColumnReference {
    let column: String
    let kind: ValueCoercion.Kind
    let isOptional: Bool
    /// Set when this column is a to-one foreign key, enabling chained traversals.
    var relationship: RelationshipMapping? = nil
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
struct SQLTranslationContext {
    let entity: EntityMapping
    let columnsByKeyPath: [AnyKeyPath: SQLColumnReference]
}

/// What a sub-expression contributes to the SQL statement.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
enum SQLTranslationFragment {
    /// The `$0` predicate input.
    case variable
    /// A reference to a column of the entity's table.
    case column(SQLColumnReference)
    /// A constant, with optionality flattened (`nil` = SQL NULL).
    case constant(Any?)
    /// An attribute reached through an optional to-one chain (`$0.playlist?.name`):
    /// comparisons resolve through a subquery over the destination table.
    case relatedColumn(foreignKey: SQLColumnReference, destinationTable: String, destination: SQLColumnReference)
    /// A complete boolean SQL expression. `mayBeNull` tracks SQL three-valued logic:
    /// clauses that can evaluate to NULL (comparisons over optional columns) must be
    /// coalesced before negation so results match Swift's optional semantics.
    case clause(String, bindings: [Sendable?], mayBeNull: Bool)

    func booleanClause() throws -> (clause: String, bindings: [Sendable?], mayBeNull: Bool) {
        switch self {
        case let .clause(sql, bindings, mayBeNull):
            return (sql, bindings, mayBeNull)
        case let .column(reference):
            // A bare boolean key path (`{ $0.done }`) is itself the predicate.
            if case .bool = reference.kind {
                return ("\(sqlQuote(reference.column)) = 1", [], reference.isOptional)
            }
            throw DataStoreError.preferInMemoryFilter
        case .variable, .constant, .relatedColumn:
            throw DataStoreError.preferInMemoryFilter
        }
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
protocol SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
private enum SQLTranslation {
    /// `Optional(Optional("x"))` becomes `"x"`; `Optional<T>.none` becomes `nil`.
    static func flattenOptional(_ value: Any) -> Any? {
        ValueCoercion.flattenOptional(value)
    }

    /// Converts a constant to a binding using the column's storage representation
    /// (`Date` -> epoch, enums -> raw value, `Bool` -> 0/1, persistent identifiers and
    /// models -> the related row's id, ...).
    static func binding(for constant: Any, kind: ValueCoercion.Kind) throws -> Sendable? {
        if let identifier = constant as? PersistentIdentifier {
            guard let primaryKey = try? PrimaryKeyResolver.primaryKey(of: identifier) else {
                throw DataStoreError.preferInMemoryFilter
            }
            return primaryKey
        }
        if let model = constant as? any PersistentModel {
            return try binding(for: model.persistentModelID, kind: kind)
        }
        do {
            return try ValueCoercion.parameter(from: constant, kind: kind, entity: "", property: "")
        } catch {
            throw DataStoreError.preferInMemoryFilter
        }
    }

    /// Builds `lhs op rhs` where one side is a column and the other a constant (or both
    /// are columns). `op` is used as written when the column is on the left; `flippedOp`
    /// when the column is on the right.
    static func comparison(
        lhs: SQLTranslationFragment,
        rhs: SQLTranslationFragment,
        op: String,
        flippedOp: String
    ) throws -> SQLTranslationFragment {
        switch (lhs, rhs) {
        case let (.column(reference), .constant(value)):
            guard let value else { throw DataStoreError.preferInMemoryFilter }
            return .clause(
                "\(sqlQuote(reference.column)) \(op) ?",
                bindings: [try binding(for: value, kind: reference.kind)],
                mayBeNull: reference.isOptional
            )
        case let (.constant(value), .column(reference)):
            guard let value else { throw DataStoreError.preferInMemoryFilter }
            return .clause(
                "\(sqlQuote(reference.column)) \(flippedOp) ?",
                bindings: [try binding(for: value, kind: reference.kind)],
                mayBeNull: reference.isOptional
            )
        case let (.column(left), .column(right)):
            return .clause(
                "\(sqlQuote(left.column)) \(op) \(sqlQuote(right.column))",
                bindings: [],
                mayBeNull: left.isOptional || right.isOptional
            )
        default:
            throw DataStoreError.preferInMemoryFilter
        }
    }

    /// Equality with SQL NULL semantics: comparisons against `nil` become `IS [NOT] NULL`.
    static func equality(
        lhs: SQLTranslationFragment,
        rhs: SQLTranslationFragment,
        negated: Bool
    ) throws -> SQLTranslationFragment {
        let column: SQLColumnReference?
        let constant: Any??
        switch (lhs, rhs) {
        case let (.column(reference), .constant(value)):
            column = reference
            constant = value
        case let (.constant(value), .column(reference)):
            column = reference
            constant = value
        default:
            column = nil
            constant = nil
        }
        switch (lhs, rhs) {
        case let (.relatedColumn(foreignKey, table, destination), .constant(value)),
             let (.constant(value), .relatedColumn(foreignKey, table, destination)):
            // Swift optional-chain semantics: a nil relationship makes == false and
            // != true, independent of the destination value.
            guard let value else {
                throw DataStoreError.preferInMemoryFilter
            }
            let fk = sqlQuote(foreignKey.column)
            let subquery = "(SELECT \(sqlQuote("id")) FROM \(sqlQuote(table)) "
                + "WHERE \(sqlQuote(destination.column)) = ?)"
            let bound = try binding(for: value, kind: destination.kind)
            if negated {
                return .clause(
                    "(\(fk) IS NULL OR \(fk) NOT IN \(subquery))",
                    bindings: [bound],
                    mayBeNull: false
                )
            }
            return .clause("\(fk) IN \(subquery)", bindings: [bound], mayBeNull: false)
        default:
            break
        }
        if let column, let constant {
            if constant == nil {
                return .clause(
                    "\(sqlQuote(column.column)) IS \(negated ? "NOT " : "")NULL",
                    bindings: [],
                    mayBeNull: false
                )
            }
            if negated, column.isOptional, let constant {
                // Swift: nil != "x" is true; SQL: NULL != 'x' is NULL (row excluded).
                let quoted = sqlQuote(column.column)
                return .clause(
                    "(\(quoted) IS NULL OR \(quoted) != ?)",
                    bindings: [try binding(for: constant, kind: column.kind)],
                    mayBeNull: false
                )
            }
            return try comparison(lhs: lhs, rhs: rhs, op: negated ? "!=" : "=", flippedOp: negated ? "!=" : "=")
        }
        return try comparison(lhs: lhs, rhs: rhs, op: negated ? "!=" : "=", flippedOp: negated ? "!=" : "=")
    }

    /// Constant elements of an `IN` list. Arrays and any other `Sequence` (such as `Set`,
    /// common with persistent identifiers) are supported.
    static func sequenceElements(of value: Any) -> [Any]? {
        if let array = value as? [Any] {
            return array
        }
        guard let sequence = value as? any Sequence else {
            return nil
        }
        func open<S: Sequence>(_ sequence: S) -> [Any] {
            sequence.map { $0 as Any }
        }
        return open(sequence)
    }

    static func escapeForLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func like(
        base: SQLTranslationFragment,
        pattern: SQLTranslationFragment,
        makePattern: (String) -> String
    ) throws -> SQLTranslationFragment {
        guard
            case let .column(reference) = base,
            case .string = reference.kind,
            case let .constant(value) = pattern,
            let text = value as? String
        else {
            throw DataStoreError.preferInMemoryFilter
        }
        return .clause(
            "\(sqlQuote(reference.column)) LIKE ? ESCAPE '\\'",
            bindings: [makePattern(escapeForLike(text))],
            mayBeNull: reference.isOptional
        )
    }
}

/// Constant ranges usable in `RangeExpressionContains`.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
private protocol SQLRangeBounds {
    var sqlLowerBound: Any { get }
    var sqlUpperBound: Any { get }
    var sqlIsClosed: Bool { get }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension ClosedRange: SQLRangeBounds {
    var sqlLowerBound: Any { lowerBound }
    var sqlUpperBound: Any { upperBound }
    var sqlIsClosed: Bool { true }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension Range: SQLRangeBounds {
    var sqlLowerBound: Any { lowerBound }
    var sqlUpperBound: Any { upperBound }
    var sqlIsClosed: Bool { false }
}

// MARK: - Supported expression nodes

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.Variable: SQLTranslatableExpression {
    func sqlFragment(in _: SQLTranslationContext) throws -> SQLTranslationFragment {
        .variable
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.KeyPath: SQLTranslatableExpression where Root: SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        guard case .variable = try root.sqlFragment(in: context) else {
            throw DataStoreError.preferInMemoryFilter
        }
        guard let reference = context.columnsByKeyPath[keyPath] else {
            throw DataStoreError.preferInMemoryFilter
        }
        return .column(reference)
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.Value: SQLTranslatableExpression {
    func sqlFragment(in _: SQLTranslationContext) throws -> SQLTranslationFragment {
        .constant(SQLTranslation.flattenOptional(value))
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.NilLiteral: SQLTranslatableExpression {
    func sqlFragment(in _: SQLTranslationContext) throws -> SQLTranslationFragment {
        .constant(nil)
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.Equal: SQLTranslatableExpression
    where LHS: SQLTranslatableExpression, RHS: SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        try SQLTranslation.equality(
            lhs: try lhs.sqlFragment(in: context),
            rhs: try rhs.sqlFragment(in: context),
            negated: false
        )
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.NotEqual: SQLTranslatableExpression
    where LHS: SQLTranslatableExpression, RHS: SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        try SQLTranslation.equality(
            lhs: try lhs.sqlFragment(in: context),
            rhs: try rhs.sqlFragment(in: context),
            negated: true
        )
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.Comparison: SQLTranslatableExpression
    where LHS: SQLTranslatableExpression, RHS: SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        let operators: (op: String, flipped: String)
        switch op {
        case .lessThan: operators = ("<", ">")
        case .lessThanOrEqual: operators = ("<=", ">=")
        case .greaterThan: operators = (">", "<")
        case .greaterThanOrEqual: operators = (">=", "<=")
        @unknown default: throw DataStoreError.preferInMemoryFilter
        }
        return try SQLTranslation.comparison(
            lhs: try lhs.sqlFragment(in: context),
            rhs: try rhs.sqlFragment(in: context),
            op: operators.op,
            flippedOp: operators.flipped
        )
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.Conjunction: SQLTranslatableExpression
    where LHS: SQLTranslatableExpression, RHS: SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        let left = try lhs.sqlFragment(in: context).booleanClause()
        let right = try rhs.sqlFragment(in: context).booleanClause()
        return .clause(
            "(\(left.clause) AND \(right.clause))",
            bindings: left.bindings + right.bindings,
            mayBeNull: left.mayBeNull || right.mayBeNull
        )
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.Disjunction: SQLTranslatableExpression
    where LHS: SQLTranslatableExpression, RHS: SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        let left = try lhs.sqlFragment(in: context).booleanClause()
        let right = try rhs.sqlFragment(in: context).booleanClause()
        return .clause(
            "(\(left.clause) OR \(right.clause))",
            bindings: left.bindings + right.bindings,
            mayBeNull: left.mayBeNull || right.mayBeNull
        )
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.OptionalFlatMap: SQLTranslatableExpression
    where LHS: SQLTranslatableExpression, RHS: SQLTranslatableExpression {
    /// `$0.playlist?.id` resolves to the foreign-key column itself; `$0.playlist?.attr`
    /// resolves to a related column compared through a subquery. The transform's key paths
    /// are rooted at the flat-map's own variable, so evaluating it with the destination
    /// entity's key-path table merged in is all the machinery needed.
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        let base = try wrapped.sqlFragment(in: context)
        guard case let .column(foreignKey) = base, let relationship = foreignKey.relationship else {
            throw DataStoreError.preferInMemoryFilter
        }
        guard let destinationEntity = SnapshotEntityRegistry.entity(named: relationship.destinationEntityName) else {
            throw DataStoreError.preferInMemoryFilter
        }
        var merged = context.columnsByKeyPath
        for (keyPath, reference) in PredicateTranslator.columnsByKeyPath(
            entity: destinationEntity,
            modelType: relationship.destinationType
        ) {
            merged[keyPath] = reference
        }
        let innerContext = SQLTranslationContext(entity: destinationEntity, columnsByKeyPath: merged)
        let inner = try transform.sqlFragment(in: innerContext)
        guard case let .column(destination) = inner else {
            throw DataStoreError.preferInMemoryFilter
        }
        if destination.column == "id" {
            // The destination id IS the foreign-key value: compare the FK directly.
            return .column(foreignKey)
        }
        return .relatedColumn(
            foreignKey: foreignKey,
            destinationTable: destinationEntity.tableName,
            destination: destination
        )
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.Negation: SQLTranslatableExpression where Wrapped: SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        let inner = try wrapped.sqlFragment(in: context).booleanClause()
        if inner.mayBeNull {
            // Swift: !(nil == "x") is true; SQL: NOT (NULL) is NULL (row excluded).
            return .clause("NOT (COALESCE((\(inner.clause)), 0))", bindings: inner.bindings, mayBeNull: false)
        }
        return .clause("NOT (\(inner.clause))", bindings: inner.bindings, mayBeNull: false)
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.SequenceContains: SQLTranslatableExpression
    where LHS: SQLTranslatableExpression, RHS: SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        guard
            case let .constant(value) = try sequence.sqlFragment(in: context),
            let value,
            let elements = SQLTranslation.sequenceElements(of: value),
            case let .column(reference) = try element.sqlFragment(in: context)
        else {
            throw DataStoreError.preferInMemoryFilter
        }
        guard !elements.isEmpty else {
            return .clause("1 = 0", bindings: [], mayBeNull: false)
        }
        let bindings = try elements.map { element -> Sendable? in
            guard let flattened = SQLTranslation.flattenOptional(element) else {
                throw DataStoreError.preferInMemoryFilter
            }
            return try SQLTranslation.binding(for: flattened, kind: reference.kind)
        }
        let placeholders = Array(repeating: "?", count: elements.count).joined(separator: ", ")
        return .clause(
            "\(sqlQuote(reference.column)) IN (\(placeholders))",
            bindings: bindings,
            mayBeNull: reference.isOptional
        )
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.ClosedRange: SQLTranslatableExpression where LHS: SQLTranslatableExpression, RHS: SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        guard
            case let .constant(lowerValue) = try lower.sqlFragment(in: context),
            case let .constant(upperValue) = try upper.sqlFragment(in: context),
            let lowerValue,
            let upperValue
        else {
            throw DataStoreError.preferInMemoryFilter
        }
        return .constant(SQLConstantRange(lower: lowerValue, upper: upperValue, isClosed: true))
    }
}

/// Carrier for ranges built from expression nodes rather than captured constants.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
private struct SQLConstantRange: SQLRangeBounds {
    let lower: Any
    let upper: Any
    let isClosed: Bool
    var sqlLowerBound: Any { lower }
    var sqlUpperBound: Any { upper }
    var sqlIsClosed: Bool { isClosed }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.RangeExpressionContains: SQLTranslatableExpression
    where RangeExpression: SQLTranslatableExpression, Element: SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        guard
            case let .constant(rangeValue) = try range.sqlFragment(in: context),
            let bounds = rangeValue as? any SQLRangeBounds,
            case let .column(reference) = try element.sqlFragment(in: context)
        else {
            throw DataStoreError.preferInMemoryFilter
        }
        let lower = try SQLTranslation.binding(for: bounds.sqlLowerBound, kind: reference.kind)
        let upper = try SQLTranslation.binding(for: bounds.sqlUpperBound, kind: reference.kind)
        let column = sqlQuote(reference.column)
        if bounds.sqlIsClosed {
            return .clause("\(column) BETWEEN ? AND ?", bindings: [lower, upper], mayBeNull: reference.isOptional)
        }
        return .clause(
            "(\(column) >= ? AND \(column) < ?)",
            bindings: [lower, upper],
            mayBeNull: reference.isOptional
        )
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.SequenceStartsWith: SQLTranslatableExpression
    where Base: SQLTranslatableExpression, Prefix: SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        try SQLTranslation.like(
            base: try base.sqlFragment(in: context),
            pattern: try prefix.sqlFragment(in: context),
            makePattern: { "\($0)%" }
        )
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension PredicateExpressions.CollectionContainsCollection: SQLTranslatableExpression
    where Base: SQLTranslatableExpression, Other: SQLTranslatableExpression {
    func sqlFragment(in context: SQLTranslationContext) throws -> SQLTranslationFragment {
        try SQLTranslation.like(
            base: try base.sqlFragment(in: context),
            pattern: try other.sqlFragment(in: context),
            makePattern: { "%\($0)%" }
        )
    }
}
