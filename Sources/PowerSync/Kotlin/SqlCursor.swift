import Foundation
import PowerSyncKotlin

extension SqlCursor {
    private func getColumnIndex(name: String) throws -> Int32 {
        guard let columnIndex = columnNames[name]?.int32Value else {
            throw SqlCursorError.columnNotFound(name)
        }
        return columnIndex
    }

    private func getValue<T>(name: String, getter: (Int32) throws -> T?) throws -> T {
        let columnIndex = try getColumnIndex(name: name)
        guard let value = try getter(columnIndex) else {
            throw SqlCursorError.nullValueFound(name)
        }
        return value
    }

    private func getOptionalValue<T>(name: String, getter: (String) throws -> T?) throws -> T? {
        _ = try getColumnIndex(name: name)
        return try getter(name)
    }

    public func getBoolean(name: String) throws -> Bool {
        try getValue(name: name) { getBoolean(index: $0)?.boolValue }
    }

    public func getDouble(name: String) throws -> Double {
        try getValue(name: name) { getDouble(index: $0)?.doubleValue }
    }

    public func getLong(name: String) throws -> Int {
        try getValue(name: name) { getLong(index: $0)?.intValue }
    }

    public func getString(name: String) throws -> String {
        try getValue(name: name) { getString(index: $0) }
    }

    public func getBooleanOptional(name: String) throws -> Bool? {
        try getOptionalValue(name: name) { try getBooleanOptional(name: $0)?.boolValue }
    }

    public func getDoubleOptional(name: String) throws -> Double? {
        try getOptionalValue(name: name) { try getDoubleOptional(name: $0)?.doubleValue }
    }

    public func getLongOptional(name: String) throws -> Int? {
        try getOptionalValue(name: name) { try getLongOptional(name: $0)?.intValue }
    }

    public func getStringOptional(name: String) throws -> String? {
        try getOptionalValue(name: name) { try PowerSyncKotlin.SqlCursorKt.getStringOptional(self, name: $0) }
    }
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
