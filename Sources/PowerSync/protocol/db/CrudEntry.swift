public enum UpdateType: String, Codable {
    /// Insert or replace a row. All non-null columns are included in the data.
    case put = "PUT"
    
    /// Update a row if it exists. All updated columns are included in the data.
    case patch = "PATCH"
    
    /// Delete a row if it exists.
    case delete = "DELETE"
    
    enum UpdateTypeStateError: Error {
        case invalidState(String)
    }
    
    static func fromString(_ input: String) throws -> UpdateType {
        guard let mapped = UpdateType.init(rawValue: input) else {
            throw UpdateTypeStateError.invalidState(input)
        }
        return mapped
    }
}

public protocol CrudEntry {
    var id: String { get }
    var clientId: Int32 { get }
    var op: UpdateType { get }
    var table: String { get }
    var transactionId: Int32? { get }
    var opData: [String: String?]? { get }
}
