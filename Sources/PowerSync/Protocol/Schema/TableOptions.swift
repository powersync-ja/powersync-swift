public protocol TableOptionsProtocol: Sendable {
    ///
    /// Whether the table only exists locally.
    ///
    var localOnly: Bool { get }
    ///
    /// Whether this is an insert-only table.
    ///
    var insertOnly: Bool { get }

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

public struct TableOptions: TableOptionsProtocol {
    ///
    /// Whether the table only exists locally.
    ///
    public let localOnly: Bool
    ///
    /// Whether this is an insert-only table.
    ///
    public let insertOnly: Bool

    /// Whether to add a hidden `_metadata` column that will ne abled for updates to
    /// attach custom information about writes.
    ///
    /// When the `_metadata` column is written to for inserts or updates, its value will not be
    /// part of ``CrudEntry/opData``. Instead, it is reported as ``CrudEntry/metadata``,
    /// allowing ``PowerSyncBackendConnector``s to handle these updates specially.
    public let trackMetadata: Bool

    /// When set to a non-`nil` value, track old values of columns for ``CrudEntry/previousValues``.
    ///
    /// See ``TrackPreviousValuesOptions`` for details
    public let trackPreviousValues: TrackPreviousValuesOptions?
    /// Whether an `UPDATE` statement that doesn't change any values should be ignored entirely when
    /// creating CRUD entries.
    ///
    /// This is disabled by default, meaning that an `UPDATE` on a row that doesn't change values would
    /// create a ``CrudEntry`` with an empty ``CrudEntry/opData`` and ``UpdateType/patch``.
    public let ignoreEmptyUpdates: Bool

    public init(
        localOnly: Bool = false,
        insertOnly: Bool = false,
        trackMetadata: Bool = false,
        trackPreviousValues: TrackPreviousValuesOptions? = nil,
        ignoreEmptyUpdates: Bool = false
    ) {
        self.localOnly = localOnly
        self.insertOnly = insertOnly
        self.trackMetadata = trackMetadata
        self.trackPreviousValues = trackPreviousValues
        self.ignoreEmptyUpdates = ignoreEmptyUpdates
    }
}

/// Options to include old values in ``CrudEntry/previousValues`` for update statements.
///
/// These options are enabled by passing them to a non-local ``Table`` constructor.
public struct TrackPreviousValuesOptions: Sendable {
    /// A filter of column names for which updates should be tracked.
    ///
    /// When set to a non-`nil` value, columns not included in this list will not appear in
    /// ``CrudEntry/previousValues``. By default, all columns are included.
    public let columnFilter: [String]?

    /// Whether to only include old values when they were changed by an update, instead of always including
    /// all old values.
    public let onlyWhenChanged: Bool

    public init(columnFilter: [String]? = nil, onlyWhenChanged: Bool = false) {
        self.columnFilter = columnFilter
        self.onlyWhenChanged = onlyWhenChanged
    }
}
