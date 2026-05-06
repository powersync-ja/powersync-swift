import CSQLite

/// Collect writes that a callback makes on a database connection.
/// 
/// We can't install commit / rollback hooks since GRDB keeps those installed, so this may also
/// return writes for transactions that have been rolled back. This may cause more queries than
/// intended to update again, which doesn't impact correctness. 
func collectWrites<T>(db: OpaquePointer, callback: () throws -> T) rethrows -> (T, Set<String>) {
    var notifications = Set<String>()
    // Install temporary update/commit/rollback hooks. GRDB should doesn't install hooks outside of
    // statements, so this doesn't interfere with GRDB (but we have an assert to be sure).
    let result = try withUnsafeMutablePointer(to: &notifications) { ptr in
        let prevUpdates = sqlite3_update_hook(db, { context, type, dbName, tableName, rowId in
            if let tableName, let context {
                let table = String(cString: tableName)
                context.assumingMemoryBound(to: Set<String>.self).pointee.insert(table)
            }
        }, ptr)
        assert(prevUpdates == nil, "Unexpected existing update hook")

        defer {
            // Uninstall our hooks
            sqlite3_update_hook(db, nil, nil)
        }

        return try callback()
    }

    return (result, notifications)
}
