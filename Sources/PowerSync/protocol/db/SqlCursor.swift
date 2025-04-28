/// A protocol representing a cursor for SQL query results, providing methods to retrieve values by column index or name.
public protocol SqlCursor {
    /// Retrieves a `Bool` value from the specified column index.
    /// - Parameter index: The zero-based index of the column.
    /// - Returns: The `Bool` value if present, or `nil` if the value is null.
    func getBoolean(index: Int) -> Bool?

    /// Retrieves a `Bool` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist, or `SqlCursorError.nullValueFound` if the value is null.
    /// - Returns: The `Bool` value.
    func getBoolean(name: String) throws -> Bool

    /// Retrieves an optional `Bool` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist.
    /// - Returns: The `Bool` value if present, or `nil` if the value is null.
    func getBooleanOptional(name: String) throws -> Bool?

    /// Retrieves a `Double` value from the specified column index.
    /// - Parameter index: The zero-based index of the column.
    /// - Returns: The `Double` value if present, or `nil` if the value is null.
    func getDouble(index: Int) -> Double?

    /// Retrieves a `Double` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist, or `SqlCursorError.nullValueFound` if the value is null.
    /// - Returns: The `Double` value.
    func getDouble(name: String) throws -> Double

    /// Retrieves an optional `Double` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist.
    /// - Returns: The `Double` value if present, or `nil` if the value is null.
    func getDoubleOptional(name: String) throws -> Double?

    /// Retrieves an `Int` value from the specified column index.
    /// - Parameter index: The zero-based index of the column.
    /// - Returns: The `Int` value if present, or `nil` if the value is null.
    func getInt(index: Int) -> Int?

    /// Retrieves an `Int` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist, or `SqlCursorError.nullValueFound` if the value is null.
    /// - Returns: The `Int` value.
    func getInt(name: String) throws -> Int

    /// Retrieves an optional `Int` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist.
    /// - Returns: The `Int` value if present, or `nil` if the value is null.
    func getIntOptional(name: String) throws -> Int?

    /// Retrieves an `Int64` value from the specified column index.
    /// - Parameter index: The zero-based index of the column.
    /// - Returns: The `Int64` value if present, or `nil` if the value is null.
    func getInt64(index: Int) -> Int64?

    /// Retrieves an `Int64` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist, or `SqlCursorError.nullValueFound` if the value is null.
    /// - Returns: The `Int64` value.
    func getInt64(name: String) throws -> Int64

    /// Retrieves an optional `Int64` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist.
    /// - Returns: The `Int64` value if present, or `nil` if the value is null.
    func getInt64Optional(name: String) throws -> Int64?

    /// Retrieves a `String` value from the specified column index.
    /// - Parameter index: The zero-based index of the column.
    /// - Returns: The `String` value if present, or `nil` if the value is null.
    func getString(index: Int) -> String?

    /// Retrieves a `String` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist, or `SqlCursorError.nullValueFound` if the value is null.
    /// - Returns: The `String` value.
    func getString(name: String) throws -> String

    /// Retrieves an optional `String` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist.
    /// - Returns: The `String` value if present, or `nil` if the value is null.
    func getStringOptional(name: String) throws -> String?

    /// The number of columns in the result set.
    var columnCount: Int { get }

    /// A dictionary mapping column names to their zero-based indices.
    var columnNames: Dictionary<String, Int> { get }
}



/// An error type representing issues encountered while working with `SqlCursor`.
enum SqlCursorError: Error {
    /// Represents a null value or a missing column.
    /// - Parameter message: A descriptive message about the error.
    case nullValue(message: String)

    /// Creates an error for a column that was not found.
    /// - Parameter name: The name of the missing column.
    /// - Returns: A `SqlCursorError` indicating the column was not found.
    static func columnNotFound(_ name: String) -> SqlCursorError {
        .nullValue(message: "Column '\(name)' not found")
    }

    /// Creates an error for a null value found in a column.
    /// - Parameter name: The name of the column with a null value.
    /// - Returns: A `SqlCursorError` indicating a null value was found.
    static func nullValueFound(_ name: String) -> SqlCursorError {
        .nullValue(message: "Null value found for column \(name)")
    }
}
