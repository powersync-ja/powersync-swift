/// Represents the type of CRUD update operation that can be performed on a row.
public enum UpdateType: String, Codable {
    /// A row has been inserted or replaced
    case put = "PUT"
    
    /// A row has been updated
    case patch = "PATCH"
    
    /// A row has been deleted
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
    
    /// User-defined metadata that can be attached to writes.
    ///
    /// This is the value the `_metadata` column had when the write to the database was made,
    /// allowing backend connectors to e.g. identify a write and tear it specially.
    ///
    /// Note that the `_metadata` column and this field are only available when ``Table/trackMetadata``
    /// is enabled.
    var metadata: String? { get }
    
    /// The operation data associated with the entry, represented as a dictionary of column names to their values.
    var opData: [String: String?]? { get }

    /// Previous values before this change.
    ///
    /// These values can be tracked for `UPDATE` statements when ``Table/trackPreviousValues`` is enabled.
    var previousValues: [String: String?]? { get }
}
