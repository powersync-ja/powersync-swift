import Foundation

///
/// Describes an indexed column.
///
public protocol IndexedColumnProtocol: Sendable {
    ///
    /// Name of the column to index.
    ///
    var column: String { get }
    ///
    /// Whether this column is stored in ascending order in the index.
    ///
    var ascending: Bool { get }
}

public struct IndexedColumn: IndexedColumnProtocol {
    public let column: String
    public let ascending: Bool

    public init(
        column: String,
        ascending: Bool = true
    ) {
        self.column = column
        self.ascending = ascending
    }

    ///
    /// Creates ascending IndexedColumn
    ///
    public static func ascending(_ column: String) -> IndexedColumn {
        IndexedColumn(column: column, ascending: true)
    }

    ///
    /// Creates descending IndexedColumn
    ///
    public static func descending(_ column: String) -> IndexedColumn {
        IndexedColumn(column: column, ascending: false)
    }
}
