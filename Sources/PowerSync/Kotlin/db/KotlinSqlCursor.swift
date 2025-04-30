import PowerSyncKotlin

/// Implements `SqlCursor` using the Kotlin SDK
class KotlinSqlCursor: SqlCursor {
    let base: PowerSyncKotlin.SqlCursor
    
    var columnCount: Int
    
    var columnNames: [String: Int]
    
    init(base: PowerSyncKotlin.SqlCursor) {
        self.base = base
        self.columnCount = Int(base.columnCount)
        self.columnNames = base.columnNames.mapValues { input in input.intValue }
    }
    
    func getBoolean(index: Int) throws -> Bool {
        guard let result = getBooleanOptional(index: index) else {
            throw SqlCursorError.nullValueFound(String(index))
        }
        return result
    }
    
    func getBooleanOptional(index: Int) -> Bool? {
        base.getBoolean(
            index: Int32(index)
        )?.boolValue
    }
    
    func getBoolean(name: String) throws -> Bool {
        guard let result = try getBooleanOptional(name: name) else {
            throw SqlCursorError.nullValueFound(name)
        }
        return result
    }
    
    func getBooleanOptional(name: String) throws -> Bool? {
        return getBooleanOptional(index: try guardColumnName(name))
    }
    
    func getDouble(index: Int) throws -> Double {
        guard let result = getDoubleOptional(index: index) else {
            throw SqlCursorError.nullValueFound(String(index))
        }
        return result
    }
    
    func getDoubleOptional(index: Int) -> Double? {
        base.getDouble(index: Int32(index))?.doubleValue
    }
    
    func getDouble(name: String) throws -> Double {
        guard let result = try getDoubleOptional(name: name) else {
            throw SqlCursorError.nullValueFound(name)
        }
        return result
    }

    func getDoubleOptional(name: String) throws -> Double? {
        return getDoubleOptional(index: try guardColumnName(name))
    }
    
    func getInt(index: Int) throws -> Int {
        guard let result = getIntOptional(index: index) else {
            throw SqlCursorError.nullValueFound(String(index))
        }
        return result
    }
    
    func getIntOptional(index: Int) -> Int? {
        base.getLong(index: Int32(index))?.intValue
    }
    
    func getInt(name: String) throws -> Int {
        guard let result = try getIntOptional(name: name) else {
            throw SqlCursorError.nullValueFound(name)
        }
        return result
    }
    
    func getIntOptional(name: String) throws -> Int? {
        return getIntOptional(index: try guardColumnName(name))
    }
    
    func getInt64(index: Int) throws -> Int64 {
        guard let result = getInt64Optional(index: index) else {
            throw SqlCursorError.nullValueFound(String(index))
        }
        return result
    }
    
    func getInt64Optional(index: Int) -> Int64? {
        base.getLong(index: Int32(index))?.int64Value
    }
    
    func getInt64(name: String) throws -> Int64 {
        guard let result = try getInt64Optional(name: name) else {
            throw SqlCursorError.nullValueFound(name)
        }
        return result
    }
    
    func getInt64Optional(name: String) throws -> Int64? {
        return getInt64Optional(index: try guardColumnName(name))
    }

    func getString(index: Int) throws -> String {
        guard let result = getStringOptional(index: index) else {
            throw SqlCursorError.nullValueFound(String(index))
        }
        return result
    }
    
    func getStringOptional(index: Int) -> String? {
        base.getString(index: Int32(index))
    }
    
    func getString(name: String) throws -> String {
        guard let result = try getStringOptional(name: name) else {
            throw SqlCursorError.nullValueFound(name)
        }
        return result
    }
    
    func getStringOptional(name: String) throws -> String? {
        return getStringOptional(index: try guardColumnName(name))
    }

    @discardableResult
    private func guardColumnName(_ name: String) throws -> Int {
        guard let index = columnNames[name] else {
            throw SqlCursorError.columnNotFound(name)
        }
        return index
    }
}
