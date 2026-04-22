import CSQLite
import Darwin
import Synchronization

private struct NativeConnectionState {
    let lease: SQLiteConnectionLease
    var closed: Bool = false
    
    func checkNotClosed() throws(PowerSyncError) {
        if self.closed {
            throw .operationFailed(message: "Attempted to use a connection context after it was closed")
        }
    }
}

final class NativeConnectionContext: ConnectionContext {
    private let state: Mutex<NativeConnectionState>;

    init(_ lease: consuming SQLiteConnectionLease) {
        self.state = Mutex(NativeConnectionState(lease: lease));
    }

    func invalidateLease() {
        state.withLock { $0.closed = true }
    }

    func execute(sql: String, parameters: [(any Sendable)?]?) throws -> Int64 {
        return try state.withLock {
            try $0.checkNotClosed()

            var stmt = try SqliteStatement(db: $0.lease, sql: sql)
            try stmt.bind_values(parameters)
            while try stmt.step() {
                // Iterate through the statement.
            }
            
            let _ = consume stmt
            return sqlite3_changes64($0.lease.pointer);
        }
    }

    func getOptional<RowType>(sql: String, parameters: [(any Sendable)?]?, mapper: @Sendable (SqlCursor) throws -> RowType) throws -> RowType? {
        return try state.withLock {
            try $0.checkNotClosed()
            
            var stmt = try SqliteStatement(db: $0.lease, sql: sql)
            try stmt.bind_values(parameters)
            if try stmt.step() {
                return try NativeConnectionContext.invokeMapper(stmt, mapper)
            } else {
                return nil
            }
        }
    }

    func getAll<RowType>(sql: String, parameters: [(any Sendable)?]?, mapper: @Sendable (SqlCursor) throws -> RowType) throws -> [RowType] {
        return try state.withLock {
            try $0.checkNotClosed()
            
            var stmt = try SqliteStatement(db: $0.lease, sql: sql)
            try stmt.bind_values(parameters)
            var rows: [RowType] = []
            while try stmt.step() {
                rows.append(try NativeConnectionContext.invokeMapper(stmt, mapper))
            }
            return rows
        }
    }

    func get<RowType>(sql: String, parameters: [(any Sendable)?]?, mapper: @Sendable (SqlCursor) throws -> RowType) throws -> RowType {
        return try state.withLock {
            try $0.checkNotClosed()
            
            var stmt = try SqliteStatement(db: $0.lease, sql: sql)
            try stmt.bind_values(parameters)
            if try stmt.step() {
                return try NativeConnectionContext.invokeMapper(stmt, mapper)
            } else {
                throw PowerSyncError.operationFailed(message: "Called get(\(sql), which did not return any row")
            }
        }
    }
    
    private static func invokeMapper<RowType>(_ stmt: borrowing SqliteStatement, _ mapper: (SqlCursor) throws -> RowType) rethrows -> RowType {
        return try withUnsafePointer(to: stmt) { ptr in
            let cursor = StatementCursor(ptr)
            defer {
                cursor.invalidate()
            }
            
            return try mapper(cursor)
        }
    }
}

struct SqliteStatement: ~Copyable {
    private var resolvedColumnNames: [String : Int]? = nil
    private let db: SQLiteConnectionLease
    let stmt: OpaquePointer
    private let sql: String
    
    init(db: SQLiteConnectionLease, sql: String) throws(PowerSyncError) {
        self.db = db
        var stmt: OpaquePointer?
        var sql = sql
        let rc = sql.withUTF8 { sqlBytes in
            return sqlite3_prepare_v2(
                db.pointer,
                sqlBytes.baseAddress,
                Int32(sqlBytes.count),
                &stmt,
                nil
            )
        }
        if (rc != 0) {
            try throwDatabaseError(db: db, sql: sql)
        }
        
        self.stmt = stmt!
        self.sql = sql
    }

    deinit {
        sqlite3_finalize(stmt)
    }
    
    var columnCount: Int {
        return Int(sqlite3_column_count(self.stmt))
    }
    
    
    var columnNames: [String : Int] {
        return resolvedColumnNames!
    }
    
    borrowing func bind_values(_ parameters: [Any?]?) throws (PowerSyncError) {
        if let parameters {
            for (i, parameter) in parameters.enumerated() {
                let index = Int32(i + 1)

                if parameter == nil {
                    try bind_value(index, nil)
                } else {
                    try bind_value(index, try PowerSyncDataType(from: parameter!))
                }
            }
        }
    }
    
    borrowing func bind_value(_ index: Int32, _ parameter: PowerSyncDataType?) throws (PowerSyncError) {
        let rc: Int32
        
        switch parameter {
        case nil:
            rc = sqlite3_bind_null(self.stmt, index)
        case .bool(let value):
            rc = sqlite3_bind_int(self.stmt, index, value ? 1 : 0)
        case .string(let value):
            var str = value
            rc = str.withUTF8 { buffer in
                sqlite3_bind_text(
                    self.stmt,
                    index,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    // SQLITE_TRANSIENT
                    unsafeBitCast(-1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self),
                )
            }
        case .int64(let value):
            rc = sqlite3_bind_int64(self.stmt, index, value)
        case .int32(let value):
            rc = sqlite3_bind_int(self.stmt, index, value)
        case .double(let value):
            rc = sqlite3_bind_double(self.stmt, index, value)
        case .data(let value):
            // Data object can be made up of multiple memory regions, so copy once.
            let buffer = malloc(value.count)!
            value.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: value.count)

            rc = sqlite3_bind_blob(
                self.stmt,
                index,
                buffer,
                Int32(value.count),
                free,
            )
            
            if rc != 0 {
                free(buffer)
            }
        }
        
        if rc != 0 {
            try throwDatabaseError(db: self.db, sql: self.sql)
        }
    }
    
    mutating func step() throws (PowerSyncError) -> Bool {
        let rc = sqlite3_step(self.stmt)
        if rc == SQLITE_DONE {
            return false
        } else if rc == SQLITE_ROW {
            if resolvedColumnNames == nil {
                let count = self.columnCount
                var nameToIndex = Dictionary<String, Int>(minimumCapacity: count)
                for i in 0..<count {
                    let name = String(cString: sqlite3_column_name(self.stmt, Int32(i)))
                    nameToIndex[name] = i
                }

                self.resolvedColumnNames = nameToIndex
            }
            
            return true
        } else {
            try throwDatabaseError(db: self.db, sql: self.sql)
        }
    }
}

/// A temporary lease of a SQLite statement used to implement cursors
class StatementCursor: SqlCursor {
    private var stmtPtr: UnsafePointer<SqliteStatement>?

    init(_ stmtPtr: UnsafePointer<SqliteStatement>) {
        self.stmtPtr = stmtPtr
    }
    
    func invalidate() {
        stmtPtr = nil
    }
    
    private func withStatement<R>(_ body: (borrowing SqliteStatement) throws -> R) rethrows -> R {
        if let stmtPtr {
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
    
    func checkColumnNotNull(stmt: borrowing SqliteStatement, index: Int) throws(SqlCursorError) {
        if index < 0 || index >= stmt.columnCount {
            throw SqlCursorError.nullValueFound("invalid index \(index)")
        }
        
        let type = sqlite3_column_type(stmt.stmt, Int32(index))
        if type == SQLITE_NULL {
            throw SqlCursorError.nullValueFound("at index \(index)")
        }
    }

    func getBoolean(index: Int) throws -> Bool {
        return try getInt(index: index) == 0 ? false : true
    }

    func getBooleanOptional(index: Int) -> Bool? {
        do {
            return try getBoolean(index: index)
        } catch {
            return nil
        }
    }

    func getDouble(index: Int) throws -> Double {
        return try withStatement { stmt in
            try self.checkColumnNotNull(stmt: stmt, index: index)
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

    func getInt(index: Int) throws -> Int {
        return Int(try getInt64(index: index))
    }
    
    func getIntOptional(index: Int) -> Int? {
        do {
            return try getInt(index: index)
        } catch {
            return nil
        }
    }

    func getInt64(index: Int) throws -> Int64 {
        return try withStatement { stmt in
            try self.checkColumnNotNull(stmt: stmt, index: index)
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

    func getString(index: Int) throws -> String {
        return try withStatement { stmt in
            try self.checkColumnNotNull(stmt: stmt, index: index)
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
