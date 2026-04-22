import CSQLite
import PowerSyncCoreShim

func registerPowerSyncCoreExtension() throws(PowerSyncError) {
    let rc = sqlite3_auto_extension(sqlite3_powersync_init)
    if rc != 0 {
        let errStr = String(cString: sqlite3_errstr(rc))

        throw .sqliteError(
            extendedResultCode: rc,
            offset: nil,
            message: "Could not load PowerSync SQLite core extension",
            errorString: errStr,
            sql: nil
        )
    }
}
