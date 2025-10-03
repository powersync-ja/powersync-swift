// The system SQLite does not expose this,
// linking PowerSync provides them
// Declare the missing function manually
@_silgen_name("sqlite3_enable_load_extension")
func sqlite3_enable_load_extension(
    _ db: OpaquePointer?,
    _ onoff: Int32
) -> Int32

@_silgen_name("sqlite3_powersync_init")
func sqlite3_powersync_init(
    _ db: OpaquePointer?,
    _: OpaquePointer?,
    _: OpaquePointer?
) -> Int32

// Similarly for sqlite3_load_extension if needed:
@_silgen_name("sqlite3_load_extension")
func sqlite3_load_extension(
    _ db: OpaquePointer?,
    _ fileName: UnsafePointer<Int8>?,
    _ procName: UnsafePointer<Int8>?,
    _ errMsg: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> Int32
