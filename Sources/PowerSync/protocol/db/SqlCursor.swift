public protocol SqlCursor {
    func getBoolean(index: Int) -> Bool?
    func getBoolean(name: String) throws -> Bool
    func getBooleanOptional(name: String) throws -> Bool?
    
    func getDouble(index: Int) -> Double?
    func getDouble(name: String) throws -> Double
    func getDoubleOptional(name: String) throws -> Double?
    
    func getInt(index: Int) -> Int?
    func getInt(name: String) throws -> Int
    func getIntOptional(name: String) throws -> Int?
    
    func getInt64(index: Int) -> Int64?
    func getInt64(name: String) throws -> Int64
    func getInt64Optional(name: String) throws -> Int64?
    
    func getString(index: Int) -> String?
    func getString(name: String) throws -> String
    func getStringOptional(name: String) throws -> String?
    
    var columnCount: Int { get }
    var columnNames: Dictionary<String, Int> { get }
}


enum SqlCursorError: Error {
    case nullValue(message: String)

    static func columnNotFound(_ name: String) -> SqlCursorError {
        .nullValue(message: "Column '\(name)' not found")
    }

    static func nullValueFound(_ name: String) -> SqlCursorError {
        .nullValue(message: "Null value found for column \(name)")
    }
}
