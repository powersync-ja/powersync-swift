import CSQLite

func throwDatabaseError(db: SQLiteConnectionLease, sql: String?) throws(PowerSyncError) -> Never {
    let extended = sqlite3_extended_errcode(db.pointer)
    let errStr = String(cString: sqlite3_errstr(extended))
    
    let offset = sqlite3_error_offset(db.pointer)
    let rawMessage = sqlite3_errmsg(db.pointer)
    
    throw PowerSyncError.sqliteError(
        extendedResultCode: extended,
        offset: offset >= 0 ? offset : nil,
        message: rawMessage.map { ptr in String(cString: ptr) },
        errorString: errStr,
        sql: sql,
    )
}
