import Foundation

/// Represents the type of CRUD update operation that can be performed on a row.
public enum UpdateType: String, Codable, Sendable {
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
        guard let mapped = UpdateType(rawValue: input) else {
            throw UpdateTypeStateError.invalidState(input)
        }
        return mapped
    }
}

/// Represents a CRUD (Create, Read, Update, Delete) entry in the system.
public struct CrudEntry: Sendable {
    /// The unique identifier of the entry.
    public let id: String

    /// The client ID associated with the entry.
    public let clientId: Int64

    /// The type of update operation performed on the entry.
    public let op: UpdateType

    /// The name of the table where the entry resides.
    public let table: String

    /// The transaction ID associated with the entry, if any.
    public let transactionId: Int64?

    /// User-defined metadata that can be attached to writes.
    ///
    /// This is the value the `_metadata` column had when the write to the database was made,
    /// allowing backend connectors to e.g. identify a write and tear it specially.
    ///
    /// Note that the `_metadata` column and this field are only available when ``Table/trackMetadata``
    /// is enabled.
    public let metadata: String?

    /// The operation data associated with the entry, represented as a dictionary of column names to their values.
    public let opDataTyped: JsonParam?

    /// The operation data associated with the entry, represented as a dictionary of column names to their values.
    ///
    /// Consider using ``CrudEntry/opDataTyped`` instead, which provides values as typed JSON.
    public var opData: [String: String?]? {
        get {
            opDataTyped?.mapValues { value in
                do {
                    return try CrudEntry.jsonValueToString(value)
                } catch {
                    return nil
                }
            }
        }
    }

    /// Previous values before this change.
    ///
    /// These values can be tracked for `UPDATE` statements when ``Table/trackPreviousValues`` is enabled.
    public let previousValuesTyped: JsonParam?

    /// Previous values before this change.
    ///
    /// These values can be tracked for `UPDATE` statements when ``Table/trackPreviousValues`` is enabled.
    ///
    /// Consider using ``CrudEntry/previousValuesTyped`` instead, which provides values as typed JSON.
    public var previousValues: [String: String?]? {
        get {
            previousValuesTyped?.mapValues { value in
                do {
                    return try CrudEntry.jsonValueToString(value)
                } catch {
                    return nil
                }
            }
        }
    }

    private let nonExhaustive: Void // Prevent initialization outside of this package

    internal static func fromCursor(cursor: borrowing SqlCursor) throws -> CrudEntry {
        let id = try cursor.getInt64(index: 0)
        let txId = cursor.getInt64Optional(index: 1)
        let data = try cursor.getString(index: 2)

        struct CrudJsonEntry: Decodable {
            let id: String
            let op: UpdateType
            let data: JsonParam?
            let type: String
            let metadata: String?
            let old: JsonParam?
        }

        let decoder = JSONDecoder()
        var entry: CrudJsonEntry
        do {
            entry = try decoder.decode(CrudJsonEntry.self, from: data.data(using: .utf8)!)
        } catch {
            throw error
        }

        return CrudEntry(
            id: entry.id,
            clientId: id,
            op: entry.op,
            table: entry.type,
            transactionId: txId,
            metadata: entry.metadata,
            opDataTyped: entry.data,
            previousValuesTyped: entry.old,
            nonExhaustive: ()
        )
    }

    private static func jsonValueToString(_ value: JsonValue?) throws -> String? {
        try value.map { value in
            switch (value) {
            case .string(let value):
                return value
            case .int(let value):
                return String(value)
            case .double(let value):
                return String(value)
            case .bool(let value):
                return String(value)
            case .null:
                return "null"
            case .array(_), .object(_):
                throw PowerSyncError.operationFailed(message: "Invalid array/object in CRUD data, should be string")
            }
        }
    }
}
