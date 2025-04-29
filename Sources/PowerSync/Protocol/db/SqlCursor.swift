import Foundation

/// A protocol representing a cursor for SQL query results, providing methods to retrieve values by column index or name.
public protocol SqlCursor {
    /// Retrieves a `Bool` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist, or `SqlCursorError.nullValueFound` if the value is null.
    /// - Returns: The `Bool` value.
    func getBoolean(index: Int) throws -> Bool

    /// Retrieves a `Bool` value from the specified column index.
    /// - Parameter index: The zero-based index of the column.
    /// - Returns: The `Bool` value if present, or `nil` if the value is null.
    func getBooleanOptional(index: Int) -> Bool?

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

    /// Retrieves a `Double` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist, or `SqlCursorError.nullValueFound` if the value is null.
    /// - Returns: The `Double` value.
    func getDouble(index: Int) throws -> Double

    /// Retrieves a `Double` value from the specified column index.
    /// - Parameter index: The zero-based index of the column.
    /// - Returns: The `Double` value if present, or `nil` if the value is null.
    func getDoubleOptional(index: Int) -> Double?

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

    /// Retrieves an `Int` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist, or `SqlCursorError.nullValueFound` if the value is null.
    /// - Returns: The `Int` value.
    func getInt(index: Int) throws -> Int

    /// Retrieves an `Int` value from the specified column index.
    /// - Parameter index: The zero-based index of the column.
    /// - Returns: The `Int` value if present, or `nil` if the value is null.
    func getIntOptional(index: Int) -> Int?

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

    /// Retrieves an `Int64` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist, or `SqlCursorError.nullValueFound` if the value is null.
    /// - Returns: The `Int64` value.
    func getInt64(index: Int) throws -> Int64

    /// Retrieves an `Int64` value from the specified column index.
    /// - Parameter index: The zero-based index of the column.
    /// - Returns: The `Int64` value if present, or `nil` if the value is null.
    func getInt64Optional(index: Int) -> Int64?

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

    /// Retrieves a `String` value from the specified column name.
    /// - Parameter name: The name of the column.
    /// - Throws: `SqlCursorError.columnNotFound` if the column does not exist, or `SqlCursorError.nullValueFound` if the value is null.
    /// - Returns: The `String` value.
    func getString(index: Int) throws -> String

    /// Retrieves a `String` value from the specified column index.
    /// - Parameter index: The zero-based index of the column.
    /// - Returns: The `String` value if present, or `nil` if the value is null.
    func getStringOptional(index: Int) -> String?

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
    var columnNames: [String: Int] { get }
}

/// An error type representing issues encountered while working with a `SqlCursor`.
public enum SqlCursorError: Error {
    /// An expected column was not found.
    case columnNotFound(_ name: String)

    /// A column contained a null value when a non-null was expected.
    case nullValueFound(_ name: String)

    /// In some cases we have to serialize an error to a single string. This deserializes potential error strings.
    static func fromDescription(_ description: String) -> SqlCursorError? {
        // Example: "SqlCursorError:columnNotFound:user_id"
        let parts = description.split(separator: ":")

        // Ensure that the string follows the expected format
        guard parts.count == 3 else { return nil }

        let type = parts[1] // "columnNotFound" or "nullValueFound"
        let name = String(parts[2]) // The column name (e.g., "user_id")

        switch type {
        case "columnNotFound":
            return .columnNotFound(name)
        case "nullValueFound":
            return .nullValueFound(name)
        default:
            return nil
        }
    }
}

public extension SqlCursorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .columnNotFound(let name):
            return "SqlCursorError:columnNotFound:\(name)"
        case .nullValueFound(let name):
            return "SqlCursorError:nullValueFound:\(name)"
        }
    }
}
