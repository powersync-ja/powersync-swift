/// Represents the type of CRUD update operation that can be performed on a row.
public enum UpdateType: String, Codable {
    /// Insert or replace a row. All non-null columns are included in the data.
    case put = "PUT"
    
    /// Update a row if it exists. All updated columns are included in the data.
    case patch = "PATCH"
    
    /// Delete a row if it exists.
    case delete = "DELETE"
    
    /// Errors related to invalid `UpdateType` states.
    enum UpdateTypeStateError: Error {
        /// Indicates an invalid state with the provided string value.
        case invalidState(String)
    }
    
    /// Converts a string to an `UpdateType` enum value.
    /// - Parameter input: The string representation of the update type.
    /// - Throws: `UpdateTypeStateError.invalidState` if the input string does not match any `UpdateType`.
    /// - Returns: The corresponding `UpdateType` enum value.
    static func fromString(_ input: String) throws -> UpdateType {
        guard let mapped = UpdateType.init(rawValue: input) else {
            throw UpdateTypeStateError.invalidState(input)
        }
        return mapped
    }
}

/// Represents a CRUD (Create, Read, Update, Delete) entry in the system.
public protocol CrudEntry {
    /// The unique identifier of the entry.
    var id: String { get }
    
    /// The client ID associated with the entry.
    var clientId: Int64 { get }
    
    /// The type of update operation performed on the entry.
    var op: UpdateType { get }
    
    /// The name of the table where the entry resides.
    var table: String { get }
    
    /// The transaction ID associated with the entry, if any.
    var transactionId: Int64? { get }
    
    /// The operation data associated with the entry, represented as a dictionary of column names to their values.
    var opData: [String: String?]? { get }
}
