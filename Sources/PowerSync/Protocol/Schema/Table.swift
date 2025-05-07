import Foundation

public protocol TableProtocol {
    ///
    /// The synced table name, matching sync rules.
    ///
    var name: String { get }
    ///
    /// List of columns.
    ///
    var columns: [Column] { get }
    ///
    /// List of indexes.
    ///
    var indexes: [Index] { get }
    ///
    /// Whether the table only exists locally.
    ///
    var localOnly: Bool { get }
    ///
    /// Whether this is an insert-only table.
    ///
    var insertOnly: Bool { get }
    ///
    /// Override the name for the view
    ///
    var viewNameOverride: String? { get }
    var viewName: String { get }
    
    /// Whether to add a hidden `_metadata` column that will ne abled for updates to
    /// attach custom information about writes.
    ///
    /// When the `_metadata` column is written to for inserts or updates, its value will not be
    /// part of ``CrudEntry/opData``. Instead, it is reported as ``CrudEntry/metadata``,
    /// allowing ``PowerSyncBackendConnector``s to handle these updates specially.
    var trackMetadata: Bool { get }
    
    /// When set to a non-`nil` value, track old values of columns for ``CrudEntry/previousValues``.
    ///
    /// See ``TrackPreviousValuesOptions`` for details
    var trackPreviousValues: TrackPreviousValuesOptions? { get }
    
    /// Whether an `UPDATE` statement that doesn't change any values should be ignored entirely when
    /// creating CRUD entries.
    ///
    /// This is disabled by default, meaning that an `UPDATE` on a row that doesn't change values would
    /// create a ``CrudEntry`` with an empty ``CrudEntry/opData`` and ``UpdateType/patch``.
    var ignoreEmptyUpdates: Bool { get }
}

/// Options to include old values in ``CrudEntry/previousValues`` for update statements.
///
/// These options are enabled by passing them to a non-local ``Table`` constructor.
public struct TrackPreviousValuesOptions {
    /// A filter of column names for which updates should be tracked.
    ///
    /// When set to a non-`nil` value, columns not included in this list will not appear in
    /// ``CrudEntry/previousValues``. By default, all columns are included.
    public let columnFilter: [String]?;
    
    /// Whether to only include old values when they were changed by an update, instead of always including
    /// all old values.
    public let onlyWhenChanged: Bool;
    
    public init(columnFilter: [String]? = nil, onlyWhenChanged: Bool = false) {
        self.columnFilter = columnFilter
        self.onlyWhenChanged = onlyWhenChanged
    }
}

private let MAX_AMOUNT_OF_COLUMNS = 63

///
/// A single table in the schema.
///
public struct Table: TableProtocol {
    public let name: String
    public let columns: [Column]
    public let indexes: [Index]
    public let localOnly: Bool
    public let insertOnly: Bool
    public let viewNameOverride: String?
    public let trackMetadata: Bool
    public let trackPreviousValues: TrackPreviousValuesOptions?
    public let ignoreEmptyUpdates: Bool

    public var viewName: String {
        viewNameOverride ?? name
    }

    internal var internalName: String {
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
        self.localOnly = localOnly
        self.insertOnly = insertOnly
        self.viewNameOverride = viewNameOverride
        self.trackMetadata = trackMetadata
        self.trackPreviousValues = trackPreviousValues
        self.ignoreEmptyUpdates = ignoreEmptyUpdates
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
           hasInvalidSqliteCharacters(viewNameOverride) {
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
