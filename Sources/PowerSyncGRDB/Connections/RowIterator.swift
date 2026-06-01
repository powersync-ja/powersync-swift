import GRDB
import PowerSync

final class RowIterator: PowerSync.SQLiteStatementIteratorProtocol {
    let rows: RowCursor
    var columnNames: [String: Int]? = nil
    
    init(rows: RowCursor) {
        self.rows = rows
    }

    func next<T>(callback: (any SqlCursor) throws -> T) throws -> T? {
        guard let row = try rows.next() else {
            return nil
        }
        
        return try callback(RowSqlCursor(columnNames: resolveColumnNames(), row: row))
    }

    private func resolveColumnNames() -> [String: Int] {
        if let columnNames {
            return columnNames
        }
        
        var names: [String: Int] = [:]
        for (i, name) in rows.columnNames.enumerated() {
            names[name] = i
        }
        columnNames = names
        return names
    }
}

struct RowSqlCursor: PowerSync.SqlCursor {
    let columnNames: [String: Int]
    let row: Row
    
    private func checkNotNull(index: Int) throws(PowerSync.SqlCursorError) {
        if row.hasNull(atIndex: index) {
            throw .nullValueFound("\(index)")
        }
    }
    
    public func getBoolean(index: Int) throws(PowerSync.SqlCursorError) -> Bool {
        try checkNotNull(index: index)
        return row.self[index]
    }
    
    public func getBooleanOptional(index: Int) -> Bool? {
        return row[index]
    }
    
    public func getDouble(index: Int) throws(PowerSync.SqlCursorError) -> Double {
        try checkNotNull(index: index)
        return row[index]
    }
    
    public func getDoubleOptional(index: Int) -> Double? {
        return row[index]
    }
    
    public func getInt(index: Int) throws(PowerSync.SqlCursorError) -> Int {
        try checkNotNull(index: index)
        return row[index]
    }

    public func getIntOptional(index: Int) -> Int? {
        return row[index]
    }
    
    public func getInt64(index: Int) throws(PowerSync.SqlCursorError) -> Int64 {
        try self.checkNotNull(index: index)
        return row[index]
    }
    
    public func getInt64Optional(index: Int) -> Int64? {
        return row[index]
    }
    
    public func getString(index: Int) throws(PowerSync.SqlCursorError) -> String {
        try self.checkNotNull(index: index)
        return row[index]
    }
    
    public func getStringOptional(index: Int) -> String? {
        return row[index]
    }
    
    public var columnCount: Int {
        row.count
    }
}
