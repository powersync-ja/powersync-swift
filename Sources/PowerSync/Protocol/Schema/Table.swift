import Foundation

/// Shared protocol for both PowerSync-managed ``Table``s as well as ``RawTable``s managed by the user.
public protocol BaseTableProtocol: Sendable {
    ///
    /// The synced table name, matching sync rules.
    ///
    var name: String { get }
}

/// Protocol for describing ``Table``s managed by PowerSync.
public protocol TableProtocol: BaseTableProtocol, TableOptionsProtocol {
    ///
    /// List of columns.
    ///
    var columns: [Column] { get }
    ///
    /// List of indexes.
    ///
    var indexes: [Index] { get }
    ///
    /// Override the name for the view
    ///
    var viewNameOverride: String? { get }
    var viewName: String { get }
}

private let MAX_AMOUNT_OF_COLUMNS = 63

///
/// A single table in the schema.
///
public struct Table: TableProtocol {
    public let name: String
    public let columns: [Column]
    public let indexes: [Index]
    public let options: TableOptions
    public let viewNameOverride: String?

    public var localOnly: Bool {
        get {
            return self.options.localOnly;
        }
    }
    public var insertOnly: Bool {
        get {
            return self.options.insertOnly
        }
    }
    public var trackMetadata: Bool {
        get {
            return self.options.trackMetadata
        }
    }
    public var trackPreviousValues: TrackPreviousValuesOptions? {
        get {
            return self.options.trackPreviousValues
        }
    }
    public var ignoreEmptyUpdates: Bool {
        get {
            return self.options.ignoreEmptyUpdates
        }
    }

    public var viewName: String {
        viewNameOverride ?? name
    }

    var internalName: String {
        localOnly ? "ps_data_local__\(name)" : "ps_data__\(name)"
    }

    private let invalidSqliteCharacters = try! NSRegularExpression(
        pattern: #"["'%,.#\s\[\]]"#,
        options: []
    )

    public init(
        name: String,
        columns: [Column],
        indexes: [Index] = [],
        localOnly: Bool = false,
        insertOnly: Bool = false,
        viewNameOverride: String? = nil,
        trackMetadata: Bool = false,
        trackPreviousValues: TrackPreviousValuesOptions? = nil,
        ignoreEmptyUpdates: Bool = false
    ) {
        self.name = name
        self.columns = columns
        self.indexes = indexes
        self.viewNameOverride = viewNameOverride
        self.options = TableOptions(
            localOnly: localOnly,
            insertOnly: insertOnly,
            trackMetadata: trackMetadata,
            trackPreviousValues: trackPreviousValues,
            ignoreEmptyUpdates: ignoreEmptyUpdates
        )
    }

    private func hasInvalidSqliteCharacters(_ string: String) -> Bool {
        let range = NSRange(location: 0, length: string.utf16.count)
        return invalidSqliteCharacters.firstMatch(in: string, options: [], range: range) != nil
    }

    ///
    /// Validate the table
    ///
    public func validate() throws {
        if columns.count > MAX_AMOUNT_OF_COLUMNS {
            throw TableError.tooManyColumns(tableName: name, count: columns.count)
        }

        if let viewNameOverride = viewNameOverride,
           hasInvalidSqliteCharacters(viewNameOverride)
        {
            throw TableError.invalidViewName(viewName: viewNameOverride)
        }

        if localOnly {
            if trackPreviousValues != nil {
                throw TableError.trackPreviousForLocalTable(tableName: name)
            }
            if trackMetadata {
                throw TableError.metadataForLocalTable(tableName: name)
            }
        }

        var columnNames = Set<String>(["id"])

        for column in columns {
            if column.name == "id" {
                throw TableError.customIdColumn(tableName: name)
            }

            if columnNames.contains(column.name) {
                throw TableError.duplicateColumn(
                    tableName: name,
                    columnName: column.name
                )
            }

            if hasInvalidSqliteCharacters(column.name) {
                throw TableError.invalidColumnName(
                    tableName: name,
                    columnName: column.name
                )
            }

            columnNames.insert(column.name)
        }

        // Check indexes
        var indexNames = Set<String>()

        for index in indexes {
            if indexNames.contains(index.name) {
                throw TableError.duplicateIndex(
                    tableName: name,
                    indexName: index.name
                )
            }

            if hasInvalidSqliteCharacters(index.name) {
                throw TableError.invalidIndexName(
                    tableName: name,
                    indexName: index.name
                )
            }

            // Check index columns exist in table
            for indexColumn in index.columns {
                if !columnNames.contains(indexColumn.column) {
                    throw TableError.columnNotFound(
                        tableName: name,
                        columnName: indexColumn.column,
                        indexName: index.name
                    )
                }
            }

            indexNames.insert(index.name)
        }
    }
}

public enum TableError: Error {
    case tooManyColumns(tableName: String, count: Int)
    case invalidTableName(tableName: String)
    case invalidViewName(viewName: String)
    case invalidColumnName(tableName: String, columnName: String)
    case duplicateColumn(tableName: String, columnName: String)
    case customIdColumn(tableName: String)
    case duplicateIndex(tableName: String, indexName: String)
    case invalidIndexName(tableName: String, indexName: String)
    case columnNotFound(tableName: String, columnName: String, indexName: String)
    /// Local-only tables can't enable ``Table/trackMetadata`` because no updates are tracked for those tables at all.
    case metadataForLocalTable(tableName: String)
    /// Local-only tables can't enable ``Table/trackPreviousValues`` because no updates are tracked for those tables at all.
    case trackPreviousForLocalTable(tableName: String)
}
