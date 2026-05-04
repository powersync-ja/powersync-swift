import CSQLite

/// Implements functions to execute and iterate through SQL statements based on a SQLite connection pointer.
extension SQLiteConnectionLease {
    func execute(sql: String, parameters: [PowerSyncDataType?]) throws -> Int64 {
        do {
            var stmt = try NativeSqliteStatement(db: pointer, sql: sql)
            try stmt.bindValues(parameters)
            while try stmt.step() {
                // Iterate through the statement.
            }
        }

        return sqlite3_changes64(pointer)
    }

    func iterate(sql: String, parameters: [PowerSyncDataType?]) throws -> NativeSqliteStatement {
        let stmt = try NativeSqliteStatement(db: pointer, sql: sql)
        try stmt.bindValues(parameters)
        return stmt
    }
}
