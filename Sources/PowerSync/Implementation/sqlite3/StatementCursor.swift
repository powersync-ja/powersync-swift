import CSQLite

/// A temporary lease of a SQLite statement used to implement cursors
class StatementCursor: SqlCursor {
    private var stmtPtr: UnsafePointer<NativeSqliteStatement>?

    init(_ stmtPtr: UnsafePointer<NativeSqliteStatement>) {
        self.stmtPtr = stmtPtr
    }
    
    func invalidate() {
        stmtPtr = nil
    }
    
    private func withStatement<R>(_ body: (borrowing NativeSqliteStatement) -> R) -> R {
        if let stmtPtr {
            return body(stmtPtr.pointee)
        }
        
        fatalError("Cursor used outside of callback")
    }

    private func checkColumnNotNull(stmt: borrowing NativeSqliteStatement, index: Int) throws(SqlCursorError) {
        if index < 0 || index >= stmt.columnCount {
            throw SqlCursorError.nullValueFound("invalid index \(index)")
        }
        
        let type = sqlite3_column_type(stmt.stmt, Int32(index))
        if type == SQLITE_NULL {
            throw SqlCursorError.nullValueFound("\(index)")
        }
    }

    private func withStatementCheckNotNull<R>(_ index: Int, body: (borrowing NativeSqliteStatement) throws (SqlCursorError) -> R) throws (SqlCursorError) -> R {
        if let stmtPtr {
            try self.checkColumnNotNull(stmt: stmtPtr.pointee, index: index)
            return try body(stmtPtr.pointee)
        }
        
        fatalError("Cursor used outside of callback")
    }

    var columnCount: Int {
        return withStatement { stmt in stmt.columnCount }
    }
    
    var columnNames: [String : Int] {
        return withStatement { stmt in stmt.columnNames }
    }

    func getBoolean(index: Int) throws(SqlCursorError) -> Bool {
        return try getInt(index: index) == 0 ? false : true
    }

    func getBooleanOptional(index: Int) -> Bool? {
        do {
            return try getBoolean(index: index)
        } catch {
            return nil
        }
    }

    func getDouble(index: Int) throws(SqlCursorError) -> Double {
        return try withStatementCheckNotNull(index) { stmt in
            return sqlite3_column_double(stmt.stmt, Int32(index))
        }
    }
    
    func getDoubleOptional(index: Int) -> Double? {
        do {
            return try getDouble(index: index)
        } catch {
            return nil
        }
    }

    func getInt(index: Int) throws(SqlCursorError) -> Int {
        return Int(try getInt64(index: index))
    }
    
    func getIntOptional(index: Int) -> Int? {
        do {
            return try getInt(index: index)
        } catch {
            return nil
        }
    }

    func getInt64(index: Int) throws(SqlCursorError) -> Int64 {
        return try withStatementCheckNotNull(index) { stmt in
            return sqlite3_column_int64(stmt.stmt, Int32(index))
        }
    }
    
    func getInt64Optional(index: Int) -> Int64? {
        do {
            return try getInt64(index: index)
        } catch {
            return nil
        }
    }

    func getString(index: Int) throws(SqlCursorError) -> String {
        return try withStatementCheckNotNull(index) { stmt in
            let length = sqlite3_column_bytes(stmt.stmt, Int32(index))
            if length == 0 {
                return ""
            }

            let ptr = sqlite3_column_text(stmt.stmt, Int32(index))
            return String(decoding: UnsafeBufferPointer(start: ptr, count: Int(length)), as: UTF8.self)
        }
    }

    func getStringOptional(index: Int) -> String? {
        do {
            return try getString(index: index)
        } catch {
            return nil
        }
    }
}
