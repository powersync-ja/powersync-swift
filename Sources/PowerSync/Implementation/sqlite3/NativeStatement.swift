import CSQLite
import Darwin

struct NativeSqliteStatement: ~Copyable {
    private var resolvedColumnNames: [String : Int]? = nil
    private let db: OpaquePointer
    let stmt: OpaquePointer
    private let sql: String
    
    init(db: OpaquePointer, sql: String) throws(PowerSyncError) {
        self.db = db
        var stmt: OpaquePointer?
        var sql = sql
        let rc = sql.withUTF8 { sqlBytes in
            return sqlite3_prepare_v2(
                db,
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
        guard let resolvedColumnNames else {
            fatalError("columnNames is only available after step()")
        }
        return resolvedColumnNames
    }
    
    borrowing func bindValues(_ parameters: [PowerSyncDataType?]) throws(PowerSyncError) {
        for (i, parameter) in parameters.enumerated() {
            let index = Int32(i + 1)

            if let parameter {
                try bindValue(index, parameter)
            } else {
                try bindValue(index, nil)
            }
        }
    }
    
    borrowing func bindValue(_ index: Int32, _ parameter: PowerSyncDataType?) throws(PowerSyncError) {
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
            if value.count == 0 {
                rc = sqlite3_bind_zeroblob(self.stmt, index, 0)
            } else {
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
            }
        }

        if rc != 0 {
            try throwDatabaseError(db: self.db, sql: self.sql)
        }
    }
    
    mutating func step() throws(PowerSyncError) -> Bool {
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
